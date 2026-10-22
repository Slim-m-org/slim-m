# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Paths from the command line, held inside the directories a tool may touch."""
import os


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
