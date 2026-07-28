"""EasyEditor desktop library server.

A thin HTTP wrapper around the semanticSearch app package: exposes your local
picture library (browse + thumbnails + files) and CLIP semantic search over
your tailnet so the EasyEditor iOS app can pull images straight into the
timeline.

Nothing is re-implemented: this imports the semanticSearch `app` package and
reuses its config, database, FAISS index, embedder, and SearchService.

Usage:
    python server.py --library "E:/02 pictures" ^
        --search-code "D:/Inbox/00 Now/202606041618 - pluginDev/semanticSearch" ^
        --port 8787 --token mysecret

Then in EasyEditor Settings, set the server to http://<tailscale-ip>:8787
(or run `tailscale serve --bg 8787` and use the https://…ts.net URL).
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import logging
import mimetypes
import os
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("easyeditor-server")

# Populated in main() after importing the semanticSearch package.
STATE: dict = {}

SUPPORTED = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff",
             ".gif", ".heic", ".heif", ".avif"}
# iOS can natively decode these; anything else gets transcoded to JPEG.
IOS_NATIVE = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".heic",
              ".heif", ".tif", ".tiff"}

THUMB_CACHE = Path(tempfile.gettempdir()) / "easyeditor-thumbs"
THUMB_CACHE.mkdir(exist_ok=True)


def resolve_safe(rel_or_abs: str) -> Path | None:
    """Resolve a request path and verify it sits under an allowed root."""
    raw = Path(rel_or_abs)
    candidates = []
    if raw.is_absolute():
        candidates.append(raw)
    else:
        candidates.append(STATE["library"] / raw)
    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        for root in STATE["roots"]:
            try:
                resolved.relative_to(root)
                return resolved
            except ValueError:
                continue
    return None


def make_thumb(path: Path, size: int = 384) -> bytes | None:
    """JPEG thumbnail, cached by path+mtime. Falls back to None on failure."""
    try:
        stat = path.stat()
    except OSError:
        return None
    key = hashlib.sha1(f"{path}|{stat.st_mtime_ns}|{size}".encode()).hexdigest()
    cached = THUMB_CACHE / f"{key}.jpg"
    if cached.exists():
        return cached.read_bytes()
    try:
        from PIL import Image
        with Image.open(path) as img:
            img = img.convert("RGB")
            img.thumbnail((size, size * 2))
            buf = io.BytesIO()
            img.save(buf, "JPEG", quality=82)
            data = buf.getvalue()
        cached.write_bytes(data)
        return data
    except Exception as e:  # HEIC without pillow-heif etc.
        log.debug("thumb failed for %s: %s", path, e)
        return None


def transcode_jpeg(path: Path) -> bytes | None:
    try:
        from PIL import Image
        with Image.open(path) as img:
            img = img.convert("RGB")
            buf = io.BytesIO()
            img.save(buf, "JPEG", quality=92)
            return buf.getvalue()
    except Exception as e:
        log.warning("transcode failed for %s: %s", path, e)
        return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quieter logs
        log.info("%s %s", self.address_string(), fmt % args)

    # -- helpers ------------------------------------------------------------

    def send_json(self, obj, status: int = 200) -> None:
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_bytes(self, data: bytes, content_type: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "max-age=86400")
        self.end_headers()
        self.wfile.write(data)

    def check_token(self, params) -> bool:
        expected = STATE.get("token")
        if not expected:
            return True
        supplied = params.get("token", [""])[0] or self.headers.get("X-Auth-Token", "")
        return supplied == expected

    # -- routes -------------------------------------------------------------

    def do_GET(self):  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        route = parsed.path

        if not self.check_token(params):
            self.send_json({"error": "unauthorized"}, status=401)
            return
        try:
            if route == "/health":
                self.handle_health()
            elif route == "/browse":
                self.handle_browse(params)
            elif route == "/search":
                self.handle_search(params)
            elif route == "/thumb":
                self.handle_thumb(params)
            elif route == "/file":
                self.handle_file(params)
            else:
                self.send_json({"error": "not found"}, status=404)
        except BrokenPipeError:
            pass
        except Exception as e:
            log.exception("request failed")
            try:
                self.send_json({"error": str(e)}, status=500)
            except Exception:
                pass

    def handle_health(self):
        index = STATE.get("index")
        self.send_json({
            "ok": True,
            "app": "easyeditor-desktop-server",
            "library": str(STATE["library"]),
            "indexReady": bool(index and index.is_ready()),
            "indexedImages": int(index.total) if index else 0,
        })

    def handle_browse(self, params):
        rel = params.get("path", [""])[0]
        target = resolve_safe(rel) if rel else STATE["library"]
        if target is None or not target.is_dir():
            self.send_json({"error": "bad path"}, status=400)
            return
        folders, images = [], []
        try:
            entries = sorted(os.scandir(target), key=lambda e: e.name.lower())
        except OSError as e:
            self.send_json({"error": str(e)}, status=400)
            return
        for entry in entries:
            name = entry.name
            if name.startswith(".") or name == "desktop.ini":
                continue
            if entry.is_dir():
                folders.append(name)
            elif Path(name).suffix.lower() in SUPPORTED:
                images.append({"path": str(Path(entry.path)), "name": name})
            if len(images) >= 1000:
                break
        self.send_json({"folders": folders, "images": images,
                        "path": str(target)})

    def handle_search(self, params):
        query = params.get("q", [""])[0].strip()
        top_k = int(params.get("k", ["60"])[0])
        if not query:
            self.send_json({"results": []})
            return
        service = STATE.get("search_service")
        if service is None:
            self.send_json({"error": "search index not available"}, status=503)
            return
        with STATE["search_lock"]:
            results = service.text_search(query, top_k=top_k)
        payload = []
        for r in results:
            p = Path(r.path)
            if resolve_safe(str(p)) is None or not p.exists():
                continue
            payload.append({
                "path": r.path,
                "name": r.filename,
                "width": r.width,
                "height": r.height,
                "score": round(r.score, 4),
            })
        self.send_json({"results": payload})

    def handle_thumb(self, params):
        path = resolve_safe(params.get("path", [""])[0])
        if path is None or not path.is_file():
            self.send_json({"error": "bad path"}, status=404)
            return
        data = make_thumb(path)
        if data is not None:
            self.send_bytes(data, "image/jpeg")
            return
        # Fallback: serve the original (iOS decodes HEIC and friends natively).
        self.serve_original(path)

    def handle_file(self, params):
        path = resolve_safe(params.get("path", [""])[0])
        if path is None or not path.is_file():
            self.send_json({"error": "bad path"}, status=404)
            return
        if path.suffix.lower() not in IOS_NATIVE:
            data = transcode_jpeg(path)
            if data is not None:
                self.send_bytes(data, "image/jpeg")
                return
        self.serve_original(path)

    def serve_original(self, path: Path):
        content_type = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        data = path.read_bytes()
        self.send_bytes(data, content_type)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, help='Picture root, e.g. "E:/02 pictures"')
    parser.add_argument("--search-code", required=True,
                        help="Path to the semanticSearch project folder")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--bind", default="0.0.0.0",
                        help="Bind address (default all; Tailscale ACLs gate access)")
    parser.add_argument("--token", default="",
                        help="Optional shared secret; the app sends it with every request")
    args = parser.parse_args()

    library = Path(args.library).resolve()
    if not library.is_dir():
        sys.exit(f"Library folder not found: {library}")

    search_root = Path(args.search_code).resolve()
    if not (search_root / "app").is_dir():
        sys.exit(f"semanticSearch app package not found in: {search_root}")
    sys.path.insert(0, str(search_root))

    STATE["library"] = library
    STATE["token"] = args.token
    STATE["search_lock"] = threading.Lock()

    roots = {library}
    try:
        from app import db
        from app.core import config, embedder as embedder_mod, vector_index
        from app.core.search import SearchService

        settings = config.get()
        db.init(settings.db_path)
        for folder in settings.folders:
            try:
                roots.add(Path(folder).resolve())
            except OSError:
                pass

        index = vector_index.get_index(512, settings.faiss_index_path)
        if index.load():
            emb = embedder_mod.get_embedder(settings.model_name, settings.device)
            STATE["index"] = index
            STATE["search_service"] = SearchService(index, emb)
            log.info("Semantic search ready: %d vectors (model %s loads on first query)",
                     index.total, settings.model_name)
        else:
            log.warning("FAISS index not found at %s — /search disabled; "
                        "run semanticSearch's index.py first", settings.faiss_index_path)
    except Exception as e:
        log.warning("semanticSearch import failed (%s) — /search disabled, browse still works", e)

    STATE["roots"] = roots
    log.info("Serving library %s on %s:%d (token %s)",
             library, args.bind, args.port, "set" if args.token else "OFF")
    log.info("Allowed roots: %s", ", ".join(map(str, roots)))

    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("bye")


if __name__ == "__main__":
    main()
