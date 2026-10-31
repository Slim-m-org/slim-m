# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The e2e web server sends the same security headers as the web image."""

import http.server
import unittest

import e2e_web_server


class ParseHeaders(unittest.TestCase):
    def test_reads_every_add_header_and_skips_comments(self):
        text = '# add_header X-Ignored "no"\nadd_header A "1" always;\n  add_header B "two words";\n'
        self.assertEqual(e2e_web_server.parse_headers(text), [("A", "1"), ("B", "two words")])

    def test_the_shipped_conf_carries_csp_and_frame_protection(self):
        names = dict(e2e_web_server.parse_headers(e2e_web_server.HEADERS_CONF.read_text()))
        self.assertIn("frame-ancestors 'none'", names["Content-Security-Policy"])
        self.assertEqual(names["X-Content-Type-Options"], "nosniff")


class ServesTheTapWorklets(unittest.TestCase):
    def test_a_tap_module_is_served_same_origin_under_the_page_csp(self):
        import threading
        import urllib.request
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            server = http.server.ThreadingHTTPServer(
                ("127.0.0.1", 0), e2e_web_server._handler(directory, [("X-Test", "1")]))
            self.addCleanup(server.server_close)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.shutdown)
            base = f"http://127.0.0.1:{server.server_address[1]}"
            for path, source in e2e_web_server.TAP_MODULES.items():
                with urllib.request.urlopen(base + path) as response:
                    self.assertEqual(response.headers["Content-Type"], "text/javascript")
                    self.assertEqual(response.read().decode(), source)
            self.assertIn("registerProcessor", e2e_web_server.TAP_MODULES["/__e2e/vq-tap.js"])

    def test_the_pages_load_the_modules_by_path_not_from_a_blob(self):
        import e2e_voice_quality_js
        import e2e_xp_js

        for js, path in ((e2e_voice_quality_js.COLLECT, "/__e2e/vq-tap.js"), (e2e_xp_js.TAP, "/__e2e/xp-tap.js")):
            self.assertIn(f"addModule('{path}')", js)
            self.assertNotIn("createObjectURL", js)


if __name__ == "__main__":
    unittest.main()
