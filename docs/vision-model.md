# Vision model — sharper website cloning (optional)

By default the builder clones a page **structurally**: it reads the page into a text digest
(palette, fonts, sections, copy, image URLs) and the coder rebuilds from that. Accurate, but
blind to pixels — so visual fidelity plateaus. A local **vision model** (`qwen2.5vl:7b`) is the
lever past that plateau: it *looks at* a screenshot of your clone beside the original and tells
the coder what's visually off.

---

## For users

### What it does

After the structural clone renders, if a vision model is installed the builder runs a
**vision-critique loop**: it screenshots your clone and the original, asks the vision model to
compare them, and feeds the concrete fixes (layout, spacing, colour, typography, missing
sections) back to the coder for another round — ending on a fresh critique so the score you see
matches what's on screen.

### Install it

Two ways:

- **In the builder:** open **🧩 Capabilities** → the **Vision model** row → **⬇ Install vision
  model**. A progress bar tracks the ~6 GB download; the row flips to **✓ Installed** when done.
- **Terminal:** `ollama pull qwen2.5vl:7b`

Either way, once it's installed the **Vision-critique clone loop** capability flips from
*Soon* to **Live**, and your next clone uses it automatically (no toggle needed).

### Requirements & honest expectations

- **~6 GB** disk for the model; **~24 GB RAM** to run it *alongside* the 14B coder. On 24 GB,
  Ollama swaps the coder and the vision model in and out each round, so **clones get noticeably
  slower** (a couple of minutes). The **Stop** button works anytime.
- It's a local **7B** vision model — expect **meaningfully closer**, not pixel-perfect.
- The first vision call of a session pays a one-time ~15–20 s model load.

### Remove it

`ollama rm qwen2.5vl:7b` — clones fall straight back to the structural path, no other change.

---

## For contributors — the gotchas we hit (don't repeat them)

Building the loop surfaced several traps. If you touch the vision path, read these first.

### 1. Ollama's default context is 4096 — two images overflow it

Each screenshot costs **~1,900 vision tokens**, so two images + a real prompt ≈ **4,168 tokens**
> the model's default **4,096** → Ollama rejects it with **HTTP 400 `exceed_context_size_error`**
*before any inference runs*. **Fix:** pass `options.num_ctx` (we use `8192`) in the `/api/chat`
request — enough for both screenshots, the prompt, and the JSON reply.

> This hid for a while because short-prompt smoke tests stayed under 4,096 and passed. Always
> test with the **production prompt + real image sizes**, not a convenient miniature.

### 2. Tiny / degenerate images are rejected

A 1×1 PNG (a common test fixture) returns **400 `"Failed to load image or audio file"`** — that's
the degenerate image, not your pipeline. Test with real screenshots.

### 3. Surface Ollama's error body

`str(urllib.error.HTTPError)` is just `"HTTP Error 400: Bad Request"` and hides the cause. Always
`e.read()` the body — the real message (`exceed_context_size_error`, `n_ctx: 4096`, exact token
counts) is what points you straight at the fix. A swallowed error body cost us the most time here.

### 4. Multimodal request shape

`POST /api/chat` with `messages: [{role:"user", content, images:[b64a, b64b]}]`. Images are
**base64 *without*** the `data:image/png;base64,` prefix. Multi-image in one message works for
qwen2.5-VL. `format:"json"` constrains the reply to valid JSON (fine alongside images, once you're
under the context limit).

### 5. Restart the agent server with the SAME interpreter

The builder serves `index.html` with `no-store`, so **frontend** edits go live on reload. The
Python agent server loads its code at startup, so **backend** edits need a **restart**. Restart
with the **same interpreter/venv** the server was launched from (a dedicated `.agent-venv` where
Playwright lives) — a naive `python3 agent-server.py` silently downgrades the screenshot backend
from **Playwright → Chrome** and lowers clone fidelity, with no error. Check the running process's
`__PYVENV_LAUNCHER__`, and verify `screenshot_backend` in `/api/agent/ping` after restarting.

### 6. Only offer in-app install for models used as-is

The vision model is pulled and consumed verbatim, so a browser-driven `POST /api/pull` (NDJSON
stream — no backend needed, CORS already open because the page POSTs `/api/chat`) fully enables
it. The **coder tiers are not**: the installer re-imports them under custom context-window / lean
alias Modelfiles (`qwen2.5-coder:14b` → `qwen2.5-coder-14b-8k`). A raw pull would be a half-install
that bypasses that pipeline. Only expose an Install button for models the runtime uses as-is.

### Architecture

The backend (`/api/agent/visioncritique`) does **one** critique: screenshot the clone + target,
call the vision model, return `{visual_score, summary, fixes[]}`. The frontend runs the **loop**
(critique → feed fixes to the coder → re-render → re-score), ending on a critique so the displayed
score matches the rendered app — mirroring the existing structural-refine loop in `index.html`.
