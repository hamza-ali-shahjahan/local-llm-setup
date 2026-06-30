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

_GOLD_CLONE = r'''<!doctype html><html class="dark"><head><meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;800&display=swap" rel="stylesheet">
<style>body{font-family:'Inter',system-ui,sans-serif}</style></head>
<body class="bg-[#0a0a0a] text-[#ededed]">
<header class="flex items-center justify-between px-8 py-5 border-b border-[#191919]">
  <span class="text-xl font-extrabold text-[#f3d5ba]">BrandName</span>
  <nav class="hidden md:flex gap-8 text-sm text-[#a1a1a1]"><a href="#">Product</a><a href="#">Pricing</a><a href="#">About</a></nav>
  <a class="bg-[#f3d5ba] text-[#0a0a0a] px-4 py-2 rounded-md text-sm font-semibold">Get started</a>
</header>
<section class="relative min-h-[70vh] flex items-center">
  <img src="https://picsum.photos/seed/hero/1600/900" class="absolute inset-0 w-full h-full object-cover opacity-40" alt="">
  <div class="relative z-10 max-w-3xl px-8">
    <h1 class="text-5xl md:text-6xl font-extrabold leading-tight">The exact hero headline</h1>
    <p class="mt-6 text-lg text-[#a1a1a1]">The real subheading copy, transcribed verbatim.</p>
    <div class="mt-8 flex gap-4"><a class="bg-[#f3d5ba] text-[#0a0a0a] px-6 py-3 rounded-md font-semibold">Primary CTA</a><a class="border border-[#191919] px-6 py-3 rounded-md">Secondary</a></div>
  </div>
</section>
<section class="px-8 py-20 max-w-6xl mx-auto">
  <h2 class="text-3xl font-bold mb-12">Real features heading</h2>
  <div class="grid md:grid-cols-3 gap-8">
    <div class="p-6 rounded-xl border border-[#191919] bg-[#111111]"><h3 class="font-semibold text-lg mb-2">Feature one</h3><p class="text-[#a1a1a1]">Real copy.</p></div>
    <div class="p-6 rounded-xl border border-[#191919] bg-[#111111]"><h3 class="font-semibold text-lg mb-2">Feature two</h3><p class="text-[#a1a1a1]">Real copy.</p></div>
    <div class="p-6 rounded-xl border border-[#191919] bg-[#111111]"><h3 class="font-semibold text-lg mb-2">Feature three</h3><p class="text-[#a1a1a1]">Real copy.</p></div>
  </div>
</section>
<footer class="px-8 py-12 border-t border-[#191919] text-sm text-[#a1a1a1] flex justify-between"><span>© BrandName</span><div class="flex gap-6"><a href="#">Terms</a><a href="#">Privacy</a></div></footer>
</body></html>'''

BUILDER_SYSTEM = (
    "You are a meticulous web-page cloner. Output ONE complete, self-contained HTML file in a single "
    "```html code block (inline any extra CSS/JS), using Tailwind utility classes (Tailwind is loaded). "
    "Recreate the page FAITHFULLY and COMPLETELY: implement EVERY section you are given, in order, each as "
    "a full block with its real heading and copy — never summarise, never shorten, never leave a placeholder "
    "like '<!-- features here -->'. A thin or partial page is a FAILURE; aim for a thorough recreation "
    "(a real landing page is typically 200+ lines). "
    "Use the EXACT colours provided, applied to the right elements as Tailwind arbitrary values "
    "(e.g. bg-[#0a0a0a], text-[#f3d5ba], border-[#191919]) — every listed colour MUST appear in the output. "
    "Match the fonts (load via Google Fonts if needed), the section order, the spacing and the visual hierarchy. "
    "For images use the real URLs if given, else https://picsum.photos/seed/NAME/W/H. Give a hero/section with "
    "a background image a real height (min-h-[70vh]) with the image as an absolute inset-0 object-cover layer "
    "behind a relative z-10 container; always set explicit text colours so nothing is invisible."
    "\n\nHere is a clone done RIGHT — study how it applies exact colours as Tailwind arbitrary values, builds a "
    "hero with an image overlay, a real multi-card features grid and a footer, with NO placeholders. Produce "
    "output of at least this completeness, then REPLACE every placeholder (BrandName, the headings/copy, and the "
    "example colours #0a0a0a/#f3d5ba/#191919/#a1a1a1/#ededed) with the REAL values from the spec you are given:\n"
    "```html\n" + _GOLD_CLONE + "\n```"
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
                 # low temp = less run-to-run variance (the reliability lever); 8k ctx + room to finish
                 "options": {"temperature": 0.2, "top_p": 0.9, "num_ctx": 8192, "num_predict": 4096},
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

def _brightness(path):
    return float(np.asarray(Image.open(path).convert("L")).mean())

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
    if d.get("theme") == "dark": L.append("IMPORTANT — this is a DARK page: near-black background (bg-zinc-950/bg-black, add class='dark' to <html>) with light text. Do NOT produce a white page.")
    elif d.get("theme") == "light": L.append("Light-themed page: light background with dark text.")
    if d.get("description"): L.append("Tagline: " + d["description"])
    if d.get("palette"): L.append("MUST use ALL of these exact colours (as Tailwind arbitrary values like bg-[#hex]/text-[#hex]) — every one has to appear in the output: " + ", ".join(d["palette"][:12]))
    if d.get("fonts"): L.append("Use THESE fonts (Google Fonts if needed): " + " · ".join(d["fonts"][:6]))
    secs = d.get("sections") or []
    if secs: L.append("Implement ALL of these sections, each as its own full block, in this exact order: " + " > ".join((s.get("tag", "") + ("#" + s["id"] if s.get("id") else "")) for s in secs[:14]))
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
    L.append("Match layout, spacing and visual hierarchy as closely as possible. Responsive. "
             "Be COMPLETE — implement every section fully with real content; a short or partial page scores poorly.")
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
    d["theme"] = "dark" if _brightness(real_png) < 110 else "light"
    base_spec = clone_spec(d)
    emit({"event": "real_captured", "theme": d["theme"], "real_brightness": round(_brightness(real_png), 1),
          "palette": len(d.get("palette", [])), "fonts": len(d.get("fonts", [])),
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
