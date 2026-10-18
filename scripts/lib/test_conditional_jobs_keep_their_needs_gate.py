# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A job carrying any `if:` loses GitHub's implicit "every need succeeded" gate.
That has shipped a real bug twice: `server-image-merge` could push a
single-arch image to `:latest` after one architecture failed, and
`server-release-assets` could publish a partial release the same way. Both
were fixed by naming the producing job's `.result` in the condition, and
`docs/ci.md` records the incident.

`copr` was the third instance, found by an audit on 2026-09-21: it consumed
`linux-client`'s tarball with an `if:` that never mentioned it. It degraded
quietly rather than shipping something wrong - both COPR scripts run
`set -uo pipefail` without `-e`, so a missing tarball became a `::warning::`
and an exit 0 - which is exactly why nobody noticed for as long as they did.

This pins the pairs by name rather than inferring "consumes an artifact",
which cannot be read off the YAML. A blanket "every need appears in the `if:`"
rule was tried and rejected: nine jobs legitimately omit `release-please`,
because the gate reaches them through `verify-server-ci` / `verify-client-ci`,
which do check it. A gate with nine false positives teaches people to ignore
it. Add a pair here when a new job starts depending on another job's output.
"""
import re
import unittest
from pathlib import Path

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"

# (workflow file, job that consumes, job whose output it consumes)
GATED_PAIRS = [
    ("release.yml", "server-image-merge", "server-image"),
    ("release.yml", "server-release-assets", "server-binaries"),
    ("release.yml", "copr", "linux-client"),
    ("release.yml", "update-manifest", "linux-client"),
    ("release.yml", "client-checksums", "linux-client"),
    ("main-builds.yml", "copr", "linux-client"),
    ("copr-catch-up.yml", "copr", "tarball"),
]


def job_block(text: str, job: str) -> str:
    """The lines of `job`'s definition, to the next job header at its indent."""
    lines = text.splitlines()
    start = next(
        (i for i, line in enumerate(lines) if line == f"  {job}:"),
        None,
    )
    if start is None:
        raise AssertionError(f"no job named {job!r}")
    body = []
    for line in lines[start + 1 :]:
        if re.match(r"^  [A-Za-z0-9_-]+:\s*$", line):
            break
        body.append(line)
    return "\n".join(body)


def condition(block: str) -> str:
    """A job's whole `if:` expression, however it is folded over lines."""
    match = re.search(r"^    if:(.*?)(?=^    [a-z][a-z-]*:)", block, re.M | re.S)
    return match.group(1) if match else ""


class ConditionalJobsKeepTheirNeedsGateTest(unittest.TestCase):
    def test_a_consuming_job_gates_on_its_producer(self):
        for workflow, consumer, producer in GATED_PAIRS:
            with self.subTest(workflow=workflow, job=consumer):
                block = job_block((WORKFLOWS / workflow).read_text(), consumer)
                self.assertRegex(
                    condition(block),
                    rf"needs\.{re.escape(producer)}\.result\s*==\s*'success'",
                    f"{workflow}'s {consumer} has an `if:` and consumes "
                    f"{producer}'s output, so it must name "
                    f"needs.{producer}.result or a failed {producer} lets it run",
                )

    def test_every_pair_names_a_real_job_in_its_needs(self):
        for workflow, consumer, producer in GATED_PAIRS:
            with self.subTest(workflow=workflow, job=consumer):
                block = job_block((WORKFLOWS / workflow).read_text(), consumer)
                needs = re.search(r"^    needs:\s*\[([^\]]*)\]", block, re.M)
                self.assertIsNotNone(needs, f"{consumer} declares no needs list")
                listed = [n.strip() for n in needs.group(1).split(",")]
                self.assertIn(producer, listed)

    def test_the_gate_itself_fails_on_a_dropped_clause(self):
        """Proves the check above is not vacuous, on a synthetic workflow."""
        synthetic = (
            "jobs:\n"
            "  producer:\n"
            "    runs-on: ubuntu-latest\n"
            "  consumer:\n"
            "    needs: [producer, other]\n"
            "    if: needs.other.result == 'success'\n"
            "    runs-on: ubuntu-latest\n"
        )
        self.assertNotRegex(
            condition(job_block(synthetic, "consumer")),
            r"needs\.producer\.result\s*==\s*'success'",
        )


if __name__ == "__main__":
    unittest.main()
