# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The e2e web server sends the same security headers as the web image."""

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


if __name__ == "__main__":
    unittest.main()
