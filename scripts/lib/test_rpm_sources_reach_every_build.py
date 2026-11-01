"""Every local `Source` in the rpm spec is copied by every workflow that builds it.

`rpmbuild` reads its inputs from one flat `SOURCES` directory, and each workflow
that builds the rpm populates that directory with its own hand-written `cp`.
There are four of them. Adding a `Source` to the spec and updating fewer than
four is a build that passes review, passes every PR check, and then fails on
main - which is exactly what happened on 2026-09-22 when `slim-m-client.repo`
was added to `release.yml`'s two copies but not to `main-builds.yml`'s or
`copr-publish.yml`'s:

    install: cannot stat '/w/rpmbuild/SOURCES/slim-m-client.repo'

No PR check builds the rpm, so nothing could have caught it earlier. This can.

Stdlib only; hygiene installs nothing.
"""

import fnmatch
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SPEC = ROOT / "packaging" / "rpm" / "slim-m-client.spec"
WORKFLOWS = ROOT / ".github" / "workflows"
ACTIONS = ROOT / ".github" / "actions"

SOURCE_LINE = re.compile(r"^Source\d+:\s*(\S+)\s*$", re.M)


def local_sources() -> list[str]:
    """The spec's Source basenames that must exist in SOURCES as files.

    A URL is excluded: `spectool -g` downloads Source0 during the COPR job, and
    the release job copies the built tarball in under the same name.
    """
    names = []
    for value in SOURCE_LINE.findall(SPEC.read_text()):
        if "://" in value:
            continue
        names.append(value.rsplit("/", 1)[-1])
    return names


COPY_INTO_SOURCES = re.compile(r"\bcp\b[^\n]*(?:\\\n[^\n]*)*?rpmbuild/SOURCES/")
JOB_HEADER = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$", re.M)


def jobs_populating_sources() -> dict[str, str]:
    """Each job that populates a SOURCES directory, mapped to its copy text.

    Scoped to the job, which is the unit that actually fails. Not the whole
    workflow: the release composites and `main-builds.yml` each populate SOURCES, and losing
    a source from one of them breaks that job while the other still names it.
    Not a single `cp` either: a job may copy the bulk of its sources in one
    command and the built tarball in another, and requiring every source in
    every command rejects that - it did, on the second version of this file.

    Only the copy commands are searched, never the surrounding YAML: a workflow
    is full of `*` that has nothing to do with sources (cron fields, path
    filters), and matching against those makes this gate pass on anything. It
    did, on the first version.
    """
    found = {}
    for path in sorted(ACTIONS.glob("*/action.yml")):
        commands = COPY_INTO_SOURCES.findall(path.read_text())
        if commands:
            found[f"{path.parent.name}/action.yml"] = "\n".join(commands)
    for path in sorted(WORKFLOWS.glob("*.yml")):
        text = path.read_text()
        if "rpmbuild/SOURCES" not in text:
            continue
        starts = [(m.start(), m.group(1)) for m in JOB_HEADER.finditer(text)]
        for index, (offset, job) in enumerate(starts):
            stop = starts[index + 1][0] if index + 1 < len(starts) else len(text)
            commands = COPY_INTO_SOURCES.findall(text[offset:stop])
            if commands:
                found[f"{path.name}:{job}"] = "\n".join(commands)
    return found


class RpmSourcesReachEveryBuildTest(unittest.TestCase):
    def test_the_spec_declares_at_least_one_local_source(self):
        self.assertTrue(
            local_sources(),
            "no local Source found; the parser has drifted from the spec",
        )

    def test_more_than_one_workflow_builds_the_rpm(self):
        self.assertGreater(
            len(jobs_populating_sources()),
            1,
            "this gate exists because several jobs each populate SOURCES by "
            "hand; if only one does now, it can be deleted",
        )

    def test_every_workflow_copies_every_local_source(self):
        names = local_sources()
        for where, text in jobs_populating_sources().items():
            tokens = [t.rsplit("/", 1)[-1] for t in text.split()]
            for name in names:
                literal = name in text
                # A bare `*` would match every name; only a real glob counts.
                globbed = any(
                    "*" in t and t != "*" and fnmatch.fnmatch(name, t)
                    for t in tokens
                )
                self.assertTrue(
                    literal or globbed,
                    f"{where} does not copy '{name}' into SOURCES, but "
                    f"{SPEC.name} declares it as a Source. rpmbuild reads one "
                    "flat directory, so the build fails on main with "
                    f"'cannot stat .../{name}'.",
                )


if __name__ == "__main__":
    unittest.main()
