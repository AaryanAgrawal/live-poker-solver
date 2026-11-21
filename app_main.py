"""One-click Mac app entry: start the trainer, open it in the browser, serve."""

import os
import socket
import threading
import time
import urllib.request
import webbrowser


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    port = free_port()
    os.environ["POKER_PORT"] = str(port)
    import server

    httpd = server.ThreadingHTTPServer(("127.0.0.1", port), server.Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    url = f"http://localhost:{port}"
    for _ in range(50):
        try:
            urllib.request.urlopen(url + "/api/health", timeout=1)
            break
        except OSError:
            time.sleep(0.1)
    webbrowser.open(url)
    print(f"Poker Trainer running at {url} — close this app to stop it.")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
