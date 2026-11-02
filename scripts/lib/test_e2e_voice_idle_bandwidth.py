# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import math
import unittest

import e2e_voice_idle_bandwidth as idle


def _row(t_ms, payload, packets):
    return {"t": t_ms, "ssrc": 1, "bytesReceived": payload, "packetsReceived": packets}


class RateBetween(unittest.TestCase):
    def test_a_steady_stream_reports_payload_packets_and_wire_rate(self):
        rows = [_row(0, 1000, 10), _row(10000, 1000 + 57500, 10 + 500)]
        got = idle.rate_between(rows, 0)
        self.assertEqual(got["seconds"], 10.0)
        self.assertEqual(got["payload_bytes_per_s"], 5750.0)
        self.assertEqual(got["packets_per_s"], 50.0)
        self.assertAlmostEqual(got["wire_kbps"], 8 * (5750 + 50 * idle.OVERHEAD_BYTES) / 1000, places=1)

    def test_a_silent_stream_with_few_packets_reads_near_zero(self):
        rows = [_row(0, 0, 0), _row(60000, 8300, 290)]
        got = idle.rate_between(rows, 0)
        self.assertLess(got["wire_kbps"], 5.0)

    def test_rows_before_the_start_index_are_ignored(self):
        rows = [_row(0, 0, 0), _row(5000, 999999, 9999), _row(10000, 1000999999, 99999)]
        self.assertEqual(idle.rate_between(rows, 1)["seconds"], 5.0)


class RoomNoise(unittest.TestCase):
    def test_it_sits_at_the_asked_level_and_repeats_for_a_seed(self):
        samples = idle.room_noise(2, -66.0)
        rms_db = 20 * math.log10(math.sqrt(sum(v * v for v in samples) / len(samples)))
        self.assertAlmostEqual(rms_db, -66.0, delta=0.5)
        self.assertEqual(samples[:50], idle.room_noise(2, -66.0)[:50])


if __name__ == "__main__":
    unittest.main()
