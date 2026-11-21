"""Screenshot poker trainer. Jev reads the screenshot, local maths decides.

  python3 server.py        then open http://localhost:8765
Play chips study tool only. No internal table, no accounts, no stored keys.
"""

import json
import os
import sys
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

import jev
import trainer

PORT = int(os.environ.get("POKER_PORT", "8765"))
HERE = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
KEY_FILE = Path.home() / "Library" / "Application Support" / "Poker Trainer" / "jev_key.txt"


def load_key(body):
    """This Mac's baked-in key: local file, else env. Never in source, never from the page."""
    if os.environ.get("JEV_API_KEY"):
        return os.environ["JEV_API_KEY"]
    try:
        return KEY_FILE.read_text().strip()
    except OSError:
        return ""


def scan(body):
    key = load_key(body)
    if not key:
        raise ValueError("No Jev key on this Mac. Add it to ~/Library/Application Support/Poker Trainer/jev_key.txt or set JEV_API_KEY.")
    if not body.get("image"):
        raise ValueError("Take or upload a screenshot first.")
    try:
        raw = jev.call_jev(body["image"], key, body.get("format", "jpeg"), body.get("model") or jev.MODEL)
    except urllib.error.HTTPError as e:
        raise ValueError(f"Jev said {e.code}: {e.read().decode()[:300]}")
    return {"schema": jev.parse_schema(raw), "usage": raw.get("usage")}


def detect(body):
    key = load_key(body)
    if not key or not body.get("image"):
        raise ValueError("Jev key and a screenshot are needed to watch for changes.")
    try:
        return jev.call_detect(body["image"], key, body.get("prev"), body.get("format", "jpeg"), body.get("model") or jev.MODEL)
    except urllib.error.HTTPError as e:
        raise ValueError(f"Jev said {e.code}: {e.read().decode()[:300]}")


def analyse(body):
    hero = trainer.parse(str(body.get("hero", "")).replace(" ", ""))
    board = trainer.parse(str(body.get("board", "")).replace(" ", ""))
    trainer.parse(str(body.get("hero", "")).replace(" ", "") + str(body.get("board", "")).replace(" ", ""))
    if len(hero) != 2 or len(board) not in (0, 3, 4, 5):
        raise ValueError("Hero must be 2 cards, board 0, 3, 4 or 5 cards.")
    return trainer.analyse(hero, board, float(body["pot"]), float(body.get("to_call") or 0),
                           int(body.get("opponents") or 1),
                           float(body["stack"]) if body.get("stack") else None,
                           str(body.get("villain") or "auto"), str(body.get("position") or "CO"))


class Handler(BaseHTTPRequestHandler):
    def send(self, body, kind="application/json", status=200):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            self.send((HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        elif path == "/app.js":
            self.send((HERE / "app.js").read_bytes(), "text/javascript; charset=utf-8")
        elif path == "/api/health":
            self.send({"ok": True})
        else:
            self.send({"error": "Not found."}, status=404)

    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            path = urlparse(self.path).path
            if path == "/api/scan":
                return self.send(scan(body))
            if path == "/api/detect":
                return self.send(detect(body))
            if path == "/api/analyse":
                return self.send(analyse(body))
            return self.send({"error": "Not found."}, status=404)
        except (ValueError, TypeError, OSError, KeyError) as error:
            self.send({"error": str(error)}, status=400)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"Poker Trainer running at http://localhost:{PORT}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
