# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""perf_baseline turns a release run's criterion output and RSS logs into a baseline."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import perf_baseline  # noqa: E402

RUN = """== glibc: target/release/slimm-server ==
  idle_rss_glibc = {ig} kB
  peak_rss_glibc = 29000 kB
== musl: slimm-server:rss-probe (via docker/server.Dockerfile) ==
  idle_rss_musl = {im} kB
  peak_rss_musl = 31000 kB
"""


def criterion(root: Path, name: str, mean: float) -> None:
    path = root / name / "new"
    path.mkdir(parents=True)
    (path / "estimates.json").write_text(json.dumps({"mean": {"point_estimate": mean}}))


class PerfBaselineTest(unittest.TestCase):
    def test_a_baseline_carries_each_bench_mean_and_the_median_of_each_rss_figure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            criterion(root, "uuid_now_v7", 91.234)
            criterion(root, "hub_publish_fanout_64", 5012.5)
            (root / "report").mkdir()
            logs = [RUN.format(ig=14000, im=17000), RUN.format(ig=13000, im=19000),
                    RUN.format(ig=15000, im=18000)]
            baseline = perf_baseline.build("0.84.0", "ci", root, logs)
        self.assertEqual(baseline["version"], "0.84.0")
        self.assertEqual(baseline["environment"], "ci")
        by_name = {m["name"]: m for m in baseline["metrics"]}
        self.assertEqual(by_name["uuid_now_v7"], {"name": "uuid_now_v7", "value": 91.23, "unit": "ns"})
        self.assertEqual(by_name["idle_rss_glibc"]["value"], 14000)
        self.assertEqual(by_name["idle_rss_musl"]["value"], 18000)
        self.assertEqual(
            [m["name"] for m in baseline["metrics"]],
            ["hub_publish_fanout_64", "uuid_now_v7", "idle_rss_glibc", "peak_rss_glibc",
             "idle_rss_musl", "peak_rss_musl"],
        )

    def test_a_run_missing_an_rss_figure_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            criterion(root, "uuid_now_v7", 91.0)
            glibc_only = RUN.split("== musl")[0]
            with self.assertRaises(ValueError):
                perf_baseline.build("0.84.0", "ci", root, [glibc_only])

    def test_no_benchmarks_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError):
            perf_baseline.build("0.84.0", "ci", Path(tmp), [RUN.format(ig=1, im=1)])

    def test_the_committed_baselines_parse_as_this_shape(self):
        for path in (Path(__file__).resolve().parents[2] / "perf" / "baselines").glob("*.json"):
            data = json.loads(path.read_text())
            self.assertEqual(data["version"], path.stem)
            for metric in data["metrics"]:
                self.assertEqual(set(metric), {"name", "value", "unit"}, path.name)


if __name__ == "__main__":
    unittest.main()
