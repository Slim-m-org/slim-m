# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Copies a file so that a cut-off copy never replaces the last good one."""
import os
import shutil


def copy(src, dest):
    partial = dest.with_name(f".{dest.name}.partial")
    try:
        shutil.copy2(src, partial)
        os.replace(partial, dest)
    finally:
        partial.unlink(missing_ok=True)
