#!/usr/bin/env python3
"""Autonomous clone-fidelity eval loop.

Drives the real measure of "how close is our clone to the real site": it
screenshots the REAL page and each generated clone (via the agent server's
screenshot endpoint, full-page), computes a VISUAL similarity score
(SSIM + colour-histogram + block-layout), feeds the structural gaps back to the
coder, and loops — logging every run to a JSONL so partial progress is never lost.

Run with the eval venv (has Pillow + numpy):
    ~/.local-llm-setup/.eval-venv/bin/python tools/clone_eval.py \
        --url https://disrupt.com --runs 30 --target 99

It talks to the running agent server (localhost:8765) for screenshots/inspect
and to Ollama (localhost:11434) for generation. Reports scores only — never
reproduces the source page's content.
"""
import argparse, json, os, re, time, urllib.request
from io import BytesIO
from PIL import Image
import numpy as np

AGENT = os.environ.get("LLM_AGENT", "http://localhost:8765")
OLLAMA = os.environ.get("OLLAMA", "http://localhost:11434")
WORKSPACE = os.path.expanduser("~/.local-llm-setup/workspace")
SHOTS = os.path.join(WORKSPACE, "shots")

BUILDER_SYSTEM = (
    "You are a local web-app builder. Tailwind CSS is loaded in the preview — use Tailwind utility "
    "classes freely. Recreate the requested page as ONE complete, self-contained HTML file in a single "
    "```html code block (inline any extra CSS/JS). Match the real colours, fonts, section order and copy "
    "given to you exactly — transcribe, don't invent. For images use https://picsum.photos/seed/NAME/W/H. "
    "Give a hero/section with a background image a real height (min-h-[70vh]) with the image as an absolute "
    "inset-0 object-cover layer behind a relative z-10 container; set explicit text colours."
)

# ---------- http helpers ----------
def _post(url, obj, timeout=120):
    req = urllib.request.Request(url, data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

def agent(ep, obj, timeout=90):
    return _post(f"{AGENT}/api/agent/{ep}", obj, timeout)

def ollama(model, system, user, timeout=600):
    out = _post(f"{OLLAMA}/api/chat",
                {"model": model, "stream": False,
                 "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]},
                timeout)
    return out.get("message", {}).get("content", "")

def best_coder():
    models = json.loads(urllib.request.urlopen(f"{OLLAMA}/api/tags", timeout=15).read())["models"]
    names = [m["name"] for m in models]
    return (next((n for n in names if re.search(r"coder.*8k", n, re.I)), None)
            or next((n for n in names if re.search(r"coder", n, re.I)), None) or names[0])

# ---------- visual similarity (SSIM + colour + block layout) ----------
def _load(path, W=900, H=1800):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    im = im.resize((W, max(1, round(h * W / w))))               # scale to width W, preserve aspect
    canvas = Image.new("RGB", (W, H), (255, 255, 255))           # white canvas, top-aligned + padded
    canvas.paste(im.crop((0, 0, W, min(H, im.size[1]))), (0, 0))
    return np.asarray(canvas, dtype=np.float64)

def _ssim(x, y):
    mx, my, vx, vy = x.mean(), y.mean(), x.var(), y.var()
    cov = ((x - mx) * (y - my)).mean()
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    return float(((2 * mx * my + c1) * (2 * cov + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2)))

def _block(x, y, grid=24):
    """Block-mean layout similarity on a 2-D map (edge or gray)."""
    H, W = x.shape[:2]; bh, bw = H // grid, W // grid
    d = []
    for i in range(grid):
        for j in range(grid):
            d.append(abs(float(x[i * bh:(i + 1) * bh, j * bw:(j + 1) * bw].mean())
                         - float(y[i * bh:(i + 1) * bh, j * bw:(j + 1) * bw].mean())))
    scale = max(float(x.mean()), float(y.mean()), 1.0)
    return float(1 - min(1.0, np.mean(d) / (2 * scale)))

def _hist(a, b, bins=12):
    ha = np.histogramdd(a.reshape(-1, 3), bins=bins, range=[[0, 255]] * 3)[0].ravel()
    hb = np.histogramdd(b.reshape(-1, 3), bins=bins, range=[[0, 255]] * 3)[0].ravel()
    ha /= ha.sum() + 1e-9; hb /= hb.sum() + 1e-9
    return float(np.minimum(ha, hb).sum())  # histogram intersection

def _sobel(g):
    gx = np.abs(np.diff(g, axis=1, prepend=g[:, :1]))
    gy = np.abs(np.diff(g, axis=0, prepend=g[:1, :]))
    return gx + gy

# Hardened visual similarity: scores WHERE the structure/content is (edge maps), not the
# background fill — with a blank-guard so a near-empty page that merely matches the site's
# dominant colour (e.g. an all-black page on a dark site) can no longer game a high score.
def visual_similarity(real_png, clone_png):
    a, b = _load(real_png), _load(clone_png)
    ga, gb = a.mean(axis=2), b.mean(axis=2)
    ea, eb = _sobel(ga), _sobel(gb)
    edge = max(0.0, _ssim(ea, eb))          # structural similarity of the EDGES (text/sections), not bg
    layout = max(0.0, _block(ea, eb))       # where that structure sits, block by block
    color = max(0.0, _hist(a, b))           # palette feel (down-weighted; most gameable)
    da, db = float(ea.mean()), float(eb.mean())
    content = min(1.0, db / (0.35 * da + 1e-6))   # blank guard: ~0 when the clone has almost no content
    raw = 0.55 * edge + 0.25 * layout + 0.20 * color
    score = raw * content
    return round(100 * max(0, min(1, score)), 1), {"edge": round(edge * 100, 1), "layout": round(layout * 100, 1),
                                                    "color": round(color * 100, 1), "content": round(content * 100, 1)}

# ---------- clone spec + generation ----------
def clone_spec(d):
    L = [f"Recreate this web page as ONE self-contained HTML file: {d.get('title') or d.get('url')}"]
    if d.get("description"): L.append("Tagline: " + d["description"])
    if d.get("palette"): L.append("Use THESE exact colours: " + ", ".join(d["palette"][:12]))
    if d.get("fonts"): L.append("Use THESE fonts (Google Fonts if needed): " + " · ".join(d["fonts"][:6]))
    secs = d.get("sections") or []
    if secs: L.append("Section order: " + " > ".join((s.get("tag", "") + ("#" + s["id"] if s.get("id") else "")) for s in secs[:14]))
    heads = d.get("headings") or []
    if heads: L.append("Headings/copy to reuse:\n" + "\n".join("- " + h.get("text", "") for h in heads[:16]))
    nav = [l.get("text", "") for l in (d.get("nav_links") or []) if l.get("text")][:8]
    if nav: L.append("Nav: " + " · ".join(nav))
    if d.get("framework"): L.append("Built with: " + str(d["framework"]))
    imgs = [(im.get("src") if isinstance(im, dict) else im) for im in (d.get("images") or [])]
    imgs = [u for u in imgs if u]
    bgs = d.get("bg_images") or []
    if imgs or bgs:
        L.append("Use the page's REAL image URLs (do NOT use picsum) in the matching spots (logo, hero, cards):")
        if bgs: L.append("Background images (hero/sections): " + "  ·  ".join(bgs[:5]))
        if imgs: L.append("<img> sources in document order: " + "  ·  ".join(imgs[:12]))
        L.append("If a real image fails to load, fall back to https://picsum.photos/seed/NAME/W/H.")
    L.append("Match layout, spacing and visual hierarchy as closely as possible. Responsive.")
    return "\n".join(L)

def extract_html(txt):
    m = re.search(r"```(?:html)?\s*([\s\S]*?)```", txt, re.I)
    code = m.group(1).strip() if m else txt.strip()
    if "cdn.tailwindcss.com" not in code and re.search(r'class\s*=\s*["\'][^"\']*\b(flex|grid|bg-|text-|p-|px-)', code):
        head = '<script src="https://cdn.tailwindcss.com"></script>'
        if re.search(r"<head[^>]*>", code, re.I): code = re.sub(r"(<head[^>]*>)", r"\1" + head, code, 1, re.I)
        else: code = "<!doctype html><html><head>" + head + "</head>" + code
    return code

def shoot(name, *, url=None, html=None):
    r = agent("screenshot", {k: v for k, v in (("url", url), ("html", html), ("name", name),
              ("full_page", True), ("width", 1280), ("height", 1600)) if v is not None}, timeout=90)
    if not r.get("ok"):
        raise RuntimeError("screenshot failed: " + str(r.get("error")))
    return os.path.join(WORKSPACE, r["path"])

# ---------- the loop ----------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--runs", type=int, default=30)
    ap.add_argument("--target", type=float, default=99.0)
    ap.add_argument("--log", default=os.path.expanduser("~/.local-llm-setup/clone_eval.jsonl"))
    a = ap.parse_args()
    coder = best_coder()
    log = open(a.log, "w")
    def emit(o): log.write(json.dumps(o) + "\n"); log.flush(); print(json.dumps(o))

    emit({"event": "start", "url": a.url, "runs": a.runs, "target": a.target, "coder": coder, "ts": time.time()})
    real_png = shoot("real_target", url=a.url)
    d = agent("inspect", {"url": a.url}, timeout=90)
    base_spec = clone_spec(d)
    emit({"event": "real_captured", "palette": len(d.get("palette", [])), "fonts": len(d.get("fonts", [])),
          "sections": len(d.get("sections", [])), "headings": len(d.get("headings", []))})

    best = {"vis": -1, "html": None}
    spec, since_gain = base_spec, 0
    for run in range(1, a.runs + 1):
        try:
            txt = ollama(coder, BUILDER_SYSTEM, "Build to THIS spec — implement every point:\n" + spec)
            html = extract_html(txt)
            cpng = shoot(f"clone_{run}", html=html)
            vis, parts = visual_similarity(real_png, cpng)
            sc = agent("score", {"a": {"url": a.url}, "b": {"html": html}}, timeout=60)
            rec = {"event": "run", "run": run, "visual": vis, "parts": parts,
                   "structural": sc.get("score") if sc.get("ok") else None,
                   "missing_colors": sc.get("missing_colors", [])[:6], "lines": html.count("\n") + 1, "ts": time.time()}
            emit(rec)
            if vis > best["vis"]:
                best = {"vis": vis, "html": html, "run": run}; since_gain = 0
            else:
                since_gain += 1
            if vis >= a.target:
                emit({"event": "hit_target", "run": run, "visual": vis}); break
            # refine toward the gaps; restart fresh if stuck
            if since_gain >= 3:
                emit({"event": "restart", "after_run": run}); spec, since_gain = base_spec, 0
            else:
                gaps = []
                if sc.get("missing_colors"): gaps.append("Use these exact colours you missed: " + ", ".join(sc["missing_colors"][:8]) + ".")
                if sc.get("missing_fonts"): gaps.append("Use these fonts: " + ", ".join(sc["missing_fonts"][:4]) + ".")
                gaps.append(f"Your clone is only {vis}% visually similar — match the layout, section sizes and spacing of the original more closely.")
                spec = base_spec + "\n\nClose these gaps:\n" + "\n".join(gaps)
        except Exception as e:
            emit({"event": "error", "run": run, "error": str(e)[:200]})
            spec, since_gain = base_spec, 0
            time.sleep(1)
    emit({"event": "done", "best_visual": best["vis"], "best_run": best.get("run"),
          "hit_target": best["vis"] >= a.target, "ts": time.time()})
    if best["html"]:
        open(os.path.expanduser("~/.local-llm-setup/clone_best.html"), "w").write(best["html"])
    log.close()

if __name__ == "__main__":
    main()
