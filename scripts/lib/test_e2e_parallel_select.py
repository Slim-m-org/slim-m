# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import unittest

import e2e_parallel as par

NAMES = ["voice join", "voice latency: chirps (opt in with E2E_ONLY)", "chat send"]


class PlannedNames(unittest.TestCase):
    def test_an_opt_in_scenario_is_left_out_by_default(self):
        self.assertEqual(par.planned_names(NAMES, ["voice"], False), ["voice join"])

    def test_the_opt_in_flag_adds_it_when_only_names_it(self):
        self.assertEqual(par.planned_names(NAMES, ["voice latency"], True),
                         ["voice latency: chirps (opt in with E2E_ONLY)"])

    def test_the_opt_in_flag_alone_never_runs_every_opt_in_scenario(self):
        self.assertEqual(par.planned_names(NAMES, [], True), ["voice join", "chat send"])


if __name__ == "__main__":
    unittest.main()
