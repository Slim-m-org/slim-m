# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Serves the e2e web bundle with the production nginx security headers.

The headers are read from docker/web-security-headers.conf, so every e2e
scenario runs under the CSP the shipped web image sends.
"""

import functools
import http.server
import re
import sys
from pathlib import Path

import e2e_voice_quality_js
import e2e_xp_js

# The audio taps' worklet modules: a CSP of script-src 'self' refuses a blob worklet.
TAP_MODULES = {
    "/__e2e/vq-tap.js": e2e_voice_quality_js.TAP_WORKLET,
    "/__e2e/xp-tap.js": e2e_xp_js.TAP_WORKLET,
}

HEADERS_CONF = Path(__file__).resolve().parents[2] / "docker" / "web-security-headers.conf"
_ADD_HEADER = re.compile(r'^\s*add_header\s+(\S+)\s+"([^"]*)"')


def parse_headers(text):
    """The (name, value) pairs of every add_header line, comments skipped."""
    pairs = []
    for line in text.splitlines():
        match = _ADD_HEADER.match(line)
        if match:
            pairs.append((match.group(1), match.group(2)))
    return pairs


def _handler(directory, headers):
    class Handler(http.server.SimpleHTTPRequestHandler):
        def end_headers(self):
            for name, value in headers:
                self.send_header(name, value)
            super().end_headers()

        def do_GET(self):
            module = TAP_MODULES.get(self.path.split("?", 1)[0])
            if module is None:
                return super().do_GET()
            body = module.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/javascript")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    return functools.partial(Handler, directory=directory)


def main(argv):
    port, directory = int(argv[1]), argv[2]
    headers = parse_headers(HEADERS_CONF.read_text())
    if not headers:
        sys.exit(f"no add_header lines in {HEADERS_CONF}")
    server = http.server.ThreadingHTTPServer(("", port), _handler(directory, headers))
    server.serve_forever()


if __name__ == "__main__":
    main(sys.argv)
