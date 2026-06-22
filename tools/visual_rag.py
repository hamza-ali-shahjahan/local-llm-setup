#!/usr/bin/env python3
"""Visual RAG — PixelRAG-inspired, Ollama-native, dependency-free.

The idea (from PixelRAG, https://github.com/StarTrail-org/PixelRAG): retrieve by what
a page *looks like*, not by its parsed text. Text extraction throws away the visual
structure — tables, charts, layout, infographics — that often holds the answer.

PixelRAG embeds the screenshot pixels directly with a fine-tuned vision model (heavy:
PyTorch + FAISS + a 2B HF checkpoint). This is the **lean, Ollama-native** take that
fits local-llm-setup's one-command, zero-extra-deps ethos:

    render → CAPTION (vision model describes the tile) → EMBED the caption
           → store {tile, caption, vector} in SQLite → cosine retrieve
           → ANSWER by handing the top tiles' IMAGES back to the vision model

So we still *retrieve over the visuals* (the caption is a faithful visual description,
and the answer step looks at the real pixels) — but every model call is just Ollama,
and the only storage is stdlib `sqlite3`. No torch, no FAISS, no transformers, no numpy.

Both models are ones a local-llm-setup user already runs (or installs in one click):
  - caption / answer : a vision model (qwen2.5vl:7b)
  - embed            : a text-embedding model (nomic-embed-text, ~274 MB)

This standalone module is the proving ground (Phase 0); the same functions get ported
into the agent server's `/api/agent/rag/*` endpoints, where rendering reuses the
existing screenshot() pipeline. Upgrade path: swap the caption-then-embed step for true
Qwen3-VL *pixel* embeddings via an Ollama GGUF once llama.cpp's image path stabilises —
the Store and retrieval code stay exactly the same.

    python tools/visual_rag.py selftest                 # end-to-end proof vs real Ollama
    python tools/visual_rag.py ingest --image a.png --source "Q3 report p4"
    python tools/visual_rag.py query  "revenue by region" --k 3
    python tools/visual_rag.py answer "what was Q3 revenue?" --k 3
    python tools/visual_rag.py list
"""
import argparse, base64, json, math, os, re, struct, sys, tempfile, time, urllib.request, urllib.error, zlib, sqlite3

OLLAMA = (os.environ.get("OLLAMA") or os.environ.get("OLLAMA_HOST") or "http://127.0.0.1:11434").rstrip("/")
DEFAULT_DB = os.path.expanduser("~/.local-llm-setup/rag/default.db")
EMBED_RE = re.compile(r'embed|bge|gte|minilm|arctic|mxbai|nomic', re.I)
VISION_RE = re.compile(r'vl|llava|vision|moondream|bakllava|minicpm-?v', re.I)
EMBED_TIMEOUT = int(os.environ.get("LLM_EMBED_TIMEOUT", "60"))
VISION_TIMEOUT = int(os.environ.get("LLM_VISION_TIMEOUT", "200"))

CAPTION_PROMPT = (
    "You are indexing this image for VISUAL SEARCH. Describe what it shows so the right "
    "page can later be found from a natural-language question. Capture, specifically: what "
    "kind of document/page it is and its topic; the visible headings and key text; any "
    "tables, charts, diagrams or figures and what they convey (axes, trends, notable "
    "numbers); important entities, dates and figures; and the overall layout and colours. "
    "Be concrete and factual — transcribe what is actually visible, do not speculate. "
    "Reply with 2-5 plain-text sentences, no preamble, no markdown."
)

ANSWER_PROMPT = (
    "Answer the question using ONLY what is visible in the image(s) provided. The images are "
    "the most visually relevant pages retrieved for this question. If the answer is not shown "
    "in them, say so plainly rather than guessing. Be concise and cite the concrete visual "
    "evidence (a heading, a table cell, a chart value) you used."
)


# ----------------------------- HTTP / Ollama -----------------------------
def _post(url, obj, timeout=120):
    req = urllib.request.Request(url, data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")


def _ollama_models():
    """Names of locally-installed Ollama models (best-effort; never raises)."""
    try:
        with urllib.request.urlopen(OLLAMA + "/api/tags", timeout=5) as r:
            data = json.loads(r.read() or b"{}")
        return [m.get("name", "") for m in data.get("models", []) if m.get("name")]
    except Exception:
        return []


def pick_vision(prefer=None):
    names = _ollama_models()
    if prefer and (prefer in names or (prefer + ":latest") in names):
        return prefer
    return next((n for n in names if VISION_RE.search(n)), None)


def pick_embedder(prefer=None):
    names = _ollama_models()
    if prefer and (prefer in names or (prefer + ":latest") in names):
        return prefer
    # Prefer a dedicated embedding model; never fall back to a chat model (wrong vectors).
    return next((n for n in names if EMBED_RE.search(n)), None)


def embed_text(text, model, timeout=EMBED_TIMEOUT):
    """One embedding vector for `text` via Ollama. Handles both the current /api/embed
    ({"input"} -> {"embeddings": [[...]]}) and the legacy /api/embeddings
    ({"prompt"} -> {"embedding": [...]}) shapes."""
    try:
        out = _post(OLLAMA + "/api/embed", {"model": model, "input": text}, timeout)
        embs = out.get("embeddings")
        if embs and isinstance(embs[0], list):
            return [float(x) for x in embs[0]]
        if isinstance(out.get("embedding"), list):
            return [float(x) for x in out["embedding"]]
    except urllib.error.HTTPError:
        pass
    out = _post(OLLAMA + "/api/embeddings", {"model": model, "prompt": text}, timeout)
    return [float(x) for x in (out.get("embedding") or [])]


def _vision_call(b64_images, prompt, model, timeout=VISION_TIMEOUT):
    """Call the vision model with one or more base64 PNGs (no data: prefix) + a prompt.
    Sizes num_ctx to the image count — each screenshot is ~1.9k vision tokens, and two
    overflow the model's 4k default (see docs/vision-model.md)."""
    n = max(1, len(b64_images))
    num_ctx = min(16384, max(4096, 2200 * n + 2000))
    body = {
        "model": model, "stream": False,
        "messages": [{"role": "user", "content": prompt, "images": b64_images}],
        "options": {"temperature": 0.2, "num_ctx": num_ctx},
    }
    try:
        out = _post(OLLAMA + "/api/chat", body, timeout)
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8", "replace")[:400]
        except Exception:
            pass
        raise RuntimeError("vision call failed (HTTP %d)%s" % (e.code, (": " + detail) if detail else ""))
    return ((out.get("message") or {}).get("content") or "").strip()


def caption(b64_png, model):
    """A dense, retrieval-oriented visual description of one tile."""
    return _vision_call([b64_png], CAPTION_PROMPT, model)


# ----------------------------- vector store -----------------------------
def cosine(a, b):
    """Pure-Python cosine similarity — no numpy. Fast enough for the thousands of tiles
    a personal knowledge base holds (brute force is instant at this scale)."""
    if not a or not b or len(a) != len(b):
        return 0.0
    s = da = db = 0.0
    for x, y in zip(a, b):
        s += x * y; da += x * x; db += y * y
    if da == 0.0 or db == 0.0:
        return 0.0
    return s / (math.sqrt(da) * math.sqrt(db))


class Store:
    """SQLite-backed tile store. One row per rendered tile: its image path, the vision
    caption, and the caption's embedding (packed float32 blob)."""

    def __init__(self, db_path=DEFAULT_DB):
        self.db_path = db_path
        os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
        self.db = sqlite3.connect(db_path)
        self.db.execute("""
            CREATE TABLE IF NOT EXISTS tiles (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source TEXT, page INTEGER, tile_path TEXT,
                caption TEXT, dim INTEGER, vec BLOB,
                embed_model TEXT, vision_model TEXT, created REAL
            )""")
        self.db.commit()

    def add(self, source, page, tile_path, caption_text, vec, embed_model, vision_model):
        blob = struct.pack("<%df" % len(vec), *vec) if vec else b""
        cur = self.db.execute(
            "INSERT INTO tiles(source,page,tile_path,caption,dim,vec,embed_model,vision_model,created)"
            " VALUES(?,?,?,?,?,?,?,?,?)",
            (source, page, tile_path, caption_text, len(vec), blob, embed_model, vision_model, time.time()))
        self.db.commit()
        return cur.lastrowid

    def all_rows(self):
        rows = []
        for r in self.db.execute("SELECT id,source,page,tile_path,caption,dim,vec FROM tiles"):
            vid, source, page, tile_path, cap, dim, blob = r
            vec = list(struct.unpack("<%df" % dim, blob)) if dim and blob else []
            rows.append({"id": vid, "source": source, "page": page, "tile_path": tile_path,
                         "caption": cap, "vec": vec})
        return rows

    def count(self):
        return self.db.execute("SELECT COUNT(*) FROM tiles").fetchone()[0]

    def clear(self):
        self.db.execute("DELETE FROM tiles"); self.db.commit()

    def close(self):
        self.db.close()


# ----------------------------- pipeline -----------------------------
def ingest_image_b64(store, b64_png, source, page, tile_path, vision_model, embed_model):
    cap = caption(b64_png, vision_model)
    vec = embed_text(cap, embed_model)
    if not vec:
        raise RuntimeError("embedding model returned no vector — is %r installed?" % embed_model)
    rid = store.add(source, page, tile_path, cap, vec, embed_model, vision_model)
    return {"id": rid, "source": source, "page": page, "caption": cap, "dim": len(vec)}


def ingest_image_file(store, path, source=None, page=0, vision_model=None, embed_model=None):
    vision_model = vision_model or pick_vision()
    embed_model = embed_model or pick_embedder()
    if not vision_model:
        raise RuntimeError("no vision model installed (need e.g. qwen2.5vl:7b)")
    if not embed_model:
        raise RuntimeError("no embedding model installed (need e.g. nomic-embed-text)")
    with open(path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    return ingest_image_b64(store, b64, source or os.path.basename(path), page,
                            os.path.abspath(path), vision_model, embed_model)


def query(store, question, embed_model=None, k=3):
    """Rank stored tiles by cosine similarity of the question's embedding to each
    tile's caption embedding. Returns the top-k rows with a `score`."""
    embed_model = embed_model or pick_embedder()
    if not embed_model:
        raise RuntimeError("no embedding model installed (need e.g. nomic-embed-text)")
    qv = embed_text(question, embed_model)
    scored = []
    for row in store.all_rows():
        row["score"] = cosine(qv, row["vec"])
        scored.append(row)
    scored.sort(key=lambda r: r["score"], reverse=True)
    return scored[:max(1, k)]


def answer(store, question, vision_model=None, embed_model=None, k=3):
    """Retrieve the top-k tiles, then let the vision model answer from their pixels."""
    vision_model = vision_model or pick_vision()
    if not vision_model:
        raise RuntimeError("no vision model installed (need e.g. qwen2.5vl:7b)")
    hits = query(store, question, embed_model, k)
    imgs = []
    for h in hits:
        p = h.get("tile_path")
        if p and os.path.isfile(p):
            with open(p, "rb") as f:
                imgs.append(base64.b64encode(f.read()).decode())
    if not imgs:
        return {"answer": "No indexed pages are available to answer from.", "hits": hits}
    captions = "\n".join("- [%s] %s" % (h["source"], (h["caption"] or "")[:200]) for h in hits)
    prompt = ANSWER_PROMPT + "\n\nRetrieved page captions (for reference):\n" + captions + "\n\nQuestion: " + question
    text = _vision_call(imgs, prompt, vision_model)
    return {"answer": text, "hits": hits}


# ----------------------------- self-test (real Ollama, no network/Playwright) -----------------------------
def _png(width, height, rgb_bytes):
    """Minimal stdlib PNG encoder (8-bit RGB, filter 0). `rgb_bytes` is width*height*3."""
    def chunk(typ, data):
        c = typ + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgb_bytes[y * width * 3:(y + 1) * width * 3]
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


class _Canvas:
    """Tiny pure-Python raster canvas — just enough to draw chart-like tiles that the
    vision model captions distinctively (bars, pie, line, grid). Real document/web tiles
    come from the screenshot pipeline; this only exists so the self-test needs no network
    or Playwright while still exercising *structured* visuals, not pathological flat colour."""

    def __init__(self, w, h, bg=(255, 255, 255)):
        self.w, self.h = w, h
        self.buf = bytearray(bytes(bg) * (w * h))

    def px(self, x, y, rgb):
        if 0 <= x < self.w and 0 <= y < self.h:
            i = (y * self.w + x) * 3
            self.buf[i:i + 3] = bytes(rgb)

    def rect(self, x0, y0, x1, y1, rgb):
        for y in range(max(0, y0), min(self.h, y1)):
            for x in range(max(0, x0), min(self.w, x1)):
                self.px(x, y, rgb)

    def line(self, x0, y0, x1, y1, rgb, width=2):
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
        err = dx + dy
        while True:
            for ox in range(-(width // 2), width // 2 + 1):
                for oy in range(-(width // 2), width // 2 + 1):
                    self.px(x0 + ox, y0 + oy, rgb)
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 >= dy: err += dy; x0 += sx
            if e2 <= dx: err += dx; y0 += sy

    def wedge(self, cx, cy, r, a0, a1, rgb):
        for y in range(cy - r, cy + r + 1):
            for x in range(cx - r, cx + r + 1):
                ddx, ddy = x - cx, y - cy
                if ddx * ddx + ddy * ddy <= r * r:
                    ang = (math.degrees(math.atan2(ddy, ddx)) + 360) % 360
                    if a0 <= ang < a1:
                        self.px(x, y, rgb)

    def png(self):
        return _png(self.w, self.h, bytes(self.buf))


def _bar_chart():
    c = _Canvas(256, 192)
    c.line(24, 168, 240, 168, (0, 0, 0), 2); c.line(24, 24, 24, 168, (0, 0, 0), 2)
    cols = [(31, 119, 180), (255, 127, 14), (44, 160, 44), (214, 39, 40), (148, 103, 189)]
    x = 40
    for h, col in zip([55, 120, 85, 150, 105], cols):
        c.rect(x, 168 - h, x + 28, 168, col); x += 40
    return c.png()


def _pie_chart():
    c = _Canvas(256, 192)
    for a0, a1, col in [(0, 90, (31, 119, 180)), (90, 200, (255, 127, 14)),
                        (200, 300, (44, 160, 44)), (300, 360, (214, 39, 40))]:
        c.wedge(128, 96, 80, a0, a1, col)
    return c.png()


def _line_graph():
    c = _Canvas(256, 192)
    c.line(24, 168, 240, 168, (0, 0, 0), 2); c.line(24, 24, 24, 168, (0, 0, 0), 2)
    pts = [(24, 150), (74, 118), (124, 128), (174, 66), (236, 38)]
    for i in range(len(pts) - 1):
        c.line(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], (214, 39, 40), 3)
    return c.png()


def _table_grid():
    c = _Canvas(256, 192)
    for i in range(6):
        c.line(24, 24 + i * 28, 232, 24 + i * 28, (0, 0, 0), 1)
    for j in range(5):
        c.line(24 + j * 52, 24, 24 + j * 52, 164, (0, 0, 0), 1)
    return c.png()


def selftest():
    """End-to-end proof against the real local models: ingest four visually-distinct
    tiles, then confirm a natural-language query retrieves the right one #1. This is the
    'does caption-then-embed actually retrieve the right page?' de-risking check."""
    vm, em = pick_vision(), pick_embedder()
    print("Ollama      : %s" % OLLAMA)
    print("vision model: %s" % (vm or "— MISSING (install qwen2.5vl:7b)"))
    print("embed model : %s" % (em or "— MISSING (install nomic-embed-text)"))
    if not vm or not em:
        print("\nFAIL — both a vision model and an embedding model must be installed.")
        return 1

    tmp = tempfile.mkdtemp(prefix="vrag_selftest_")
    tiles = {
        "bar-chart":  _bar_chart(),
        "pie-chart":  _pie_chart(),
        "line-graph": _line_graph(),
        "table":      _table_grid(),
    }
    db = os.path.join(tmp, "selftest.db")
    store = Store(db)
    print("\nIngesting %d tiles (caption → embed → store)…" % len(tiles))
    for name, png in tiles.items():
        path = os.path.join(tmp, name + ".png")
        with open(path, "wb") as f:
            f.write(png)
        t0 = time.time()
        info = ingest_image_file(store, path, source=name, vision_model=vm, embed_model=em)
        print("  • %-11s dim=%d  %4.1fs  “%s”" % (name, info["dim"], time.time() - t0,
                                                   (info["caption"] or "")[:70].replace("\n", " ")))

    checks = [("a bar chart with vertical bars comparing values", "bar-chart"),
              ("a pie chart split into coloured slices", "pie-chart"),
              ("a line graph showing a trend over time", "line-graph"),
              ("a table grid of rows and columns", "table")]
    print("\nRetrieval checks:")
    ok = True
    for q, expect in checks:
        top = query(store, q, embed_model=em, k=len(tiles))
        winner = top[0]["source"]
        passed = winner == expect
        ok = ok and passed
        print("  [%s] %-42s → #1 %-11s (%.3f) %s"
              % ("PASS" if passed else "FAIL", repr(q), winner, top[0]["score"],
                 "" if passed else "(expected %s)" % expect))
        if not passed:
            print("        ranking: " + ", ".join("%s=%.3f" % (r["source"], r["score"]) for r in top))

    store.close()
    print("\n%s — caption-then-embed visual retrieval %s."
          % (("PASS" if ok else "FAIL"), ("works end-to-end" if ok else "did not rank correctly")))
    return 0 if ok else 1


# ----------------------------- CLI -----------------------------
def main():
    ap = argparse.ArgumentParser(description="Visual RAG — lean, Ollama-native (PixelRAG-inspired).")
    ap.add_argument("cmd", choices=["selftest", "ingest", "query", "answer", "list", "clear"])
    ap.add_argument("text", nargs="?", default="", help="question for query/answer")
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--image", help="image file to ingest")
    ap.add_argument("--source", help="label for the ingested tile")
    ap.add_argument("--page", type=int, default=0)
    ap.add_argument("--k", type=int, default=3)
    ap.add_argument("--vision", help="override vision model")
    ap.add_argument("--embed", help="override embedding model")
    a = ap.parse_args()

    if a.cmd == "selftest":
        return selftest()

    store = Store(a.db)
    try:
        if a.cmd == "ingest":
            if not a.image:
                ap.error("ingest needs --image")
            info = ingest_image_file(store, a.image, a.source, a.page,
                                     pick_vision(a.vision), pick_embedder(a.embed))
            print(json.dumps(info, indent=2))
        elif a.cmd == "query":
            for h in query(store, a.text, pick_embedder(a.embed), a.k):
                print("%.3f  [%s]  %s" % (h["score"], h["source"], (h["caption"] or "")[:90].replace("\n", " ")))
        elif a.cmd == "answer":
            res = answer(store, a.text, pick_vision(a.vision), pick_embedder(a.embed), a.k)
            print(res["answer"])
            print("\n— grounded in: " + ", ".join("%s (%.3f)" % (h["source"], h["score"]) for h in res["hits"]))
        elif a.cmd == "list":
            print("%d tiles in %s" % (store.count(), a.db))
            for r in store.all_rows():
                print("  #%d [%s p%s] %s" % (r["id"], r["source"], r["page"], (r["caption"] or "")[:80].replace("\n", " ")))
        elif a.cmd == "clear":
            store.clear(); print("cleared %s" % a.db)
    finally:
        store.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
