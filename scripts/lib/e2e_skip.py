# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Raised by an opt-in scenario that was not selected, so the run records a skip."""


class Skip(Exception):
    pass
