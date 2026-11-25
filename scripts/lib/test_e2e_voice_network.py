# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import unittest
from unittest import mock

import e2e_voice_network as net


class StayOfflineTest(unittest.TestCase):
    def setUp(self):
        for name, value in (("DROP_SECONDS", 0.3), ("EVICTED_GRACE", 0)):
            patcher = mock.patch.object(net, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_it_reports_the_eviction_once_the_sfu_drops_the_participant(self):
        with mock.patch.object(net, "sfu_participants", side_effect=[[1, 2], [1]] + [[1]] * 50):
            _, evicted = net._stay_offline_until_evicted("room")
        self.assertTrue(evicted)

    def test_it_reports_no_eviction_when_the_sfu_never_lets_go(self):
        with mock.patch.object(net, "sfu_participants", return_value=[1, 2]):
            _, evicted = net._stay_offline_until_evicted("room")
        self.assertFalse(evicted)


if __name__ == "__main__":
    unittest.main()
