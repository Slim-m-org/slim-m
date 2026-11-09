# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Paths from the command line, held inside the directories a tool may touch."""
import os
import sys


def confined(path, *bases):
    """The resolved [path], refused unless it sits strictly inside one of [bases]."""
    resolved = os.path.realpath(path)
    for base in bases:
        root = os.path.realpath(base)
        if resolved.startswith(root + os.sep):
            return resolved
    raise SystemExit(f"{path} must be inside {' or '.join(bases)}")


def home_or_cwd(path):
    """[path] held inside the home directory or the working directory."""
    return confined(path, os.path.expanduser("~"), os.getcwd())


def main(argv):
    """`confined PATH BASE...` prints the resolved PATH for a shell script, or refuses with the reason."""
    if len(argv) < 4 or argv[1] != "confined":
        raise SystemExit(f"usage: {argv[0]} confined PATH BASE...")
    print(confined(argv[2], *argv[3:]))


if __name__ == "__main__":
    main(sys.argv)
