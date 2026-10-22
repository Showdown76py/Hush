#!/usr/bin/env python3
"""Serves site/ for the hush.showdown.boo deployment (Pelican, Python egg, standard library only).

The egg clones the repo into /home/container and runs this file. Only site/ is served, never the rest of
the repo or .git. A git pull every 10 minutes puts pushes online without a restart.

usage: SERVER_PORT=8765 scripts/serve-site.py
"""
import functools
import http.server
import os
import subprocess
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")
PULL_EVERY = 600


class Handler(http.server.SimpleHTTPRequestHandler):
    # the container's mime table misses some of these, and safari won't decode audio/mp4a-latm
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".html": "text/html; charset=utf-8",
        ".css": "text/css; charset=utf-8",
        ".js": "text/javascript; charset=utf-8",
        ".json": "application/json",
        ".webp": "image/webp",
        ".m4a": "audio/mp4",
    }

    def end_headers(self):
        html = self.path.split("?")[0].endswith(("/", ".html"))
        self.send_header("Cache-Control", "no-cache" if html else "public, max-age=3600")
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()

    def log_message(self, format, *args):
        pass


def pull_forever():
    while True:
        time.sleep(PULL_EVERY)
        subprocess.run(["git", "-C", ROOT, "pull", "--ff-only", "-q"], capture_output=True)


def main():
    port = int(os.environ.get("SERVER_PORT", "8765"))
    threading.Thread(target=pull_forever, daemon=True).start()
    server = http.server.ThreadingHTTPServer(("0.0.0.0", port), functools.partial(Handler, directory=SITE))
    # the egg marks the server as running once it sees this line
    print(f"Done, serving {SITE} on port {port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
