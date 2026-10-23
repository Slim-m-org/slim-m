#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A loopback stand-in for LiveKit's ListParticipants, so the roster route has an SFU to ask.

Answers every room with the same two participants after a fixed delay, and counts the
calls it gets, so a run shows how many roster requests actually reached the SFU.
usage: load_fake_livekit.py PORT DELAY_MS COUNT_FILE
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PARTICIPANTS = [
    {"identity": "018f0000-0000-7000-8000-00000000000%d" % n, "name": "Load %d" % n,
     "tracks": [{"source": "MICROPHONE", "type": "AUDIO"}], "joinedAt": "1760000000"}
    for n in (1, 2)
]


class Handler(BaseHTTPRequestHandler):
    delay = 0.0
    count_file = ""
    calls = 0
    lock = threading.Lock()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        time.sleep(self.delay)
        with Handler.lock:
            Handler.calls += 1
            calls = Handler.calls
        body = json.dumps({"participants": PARTICIPANTS}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        with open(Handler.count_file, "w") as out:
            out.write(f"{calls}\n")

    def log_message(self, *_):
        return  # a load run would drown in a line per request


def main():
    port, delay_ms, Handler.count_file = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
    Handler.delay = delay_ms / 1000
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
