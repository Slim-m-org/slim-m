# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Which scenarios a run takes, how each one ends, and whether the run passed."""
import time
import traceback

from e2e_skip import Skip


def selected(name, only, exact):
    """Whether [name] runs: an exact list wins, then name fragments, else all."""
    if exact is not None:
        return name in exact
    return not only or any(o in name for o in only)


def run_selected(scenario_list, only, exact, prepare):
    """Runs each selected scenario; a failure is recorded and the run goes on."""
    results = []
    for name, run in scenario_list:
        if not selected(name, only, exact):
            continue
        print(f"\n== {name} ==")
        began = time.time()
        try:
            prepare()
            run()
            took = time.time() - began
            results.append({"name": name, "ok": True, "seconds": round(took, 1)})
            print(f"  ({took:.0f}s)")
        except Skip:
            results.append({"name": name, "ok": None, "skipped": True, "seconds": 0.0})
        except Exception:
            results.append({"name": name, "ok": False,
                            "seconds": round(time.time() - began, 1)})
            # One broken scenario must not hide the state of the ones after it.
            traceback.print_exc()
            print(f"  FAILED: {name}")
    return results


def verdict(results):
    """The exit code and closing line; a run that exercised nothing is a failure."""
    failures = [r["name"] for r in results if r["ok"] is False]
    ran = [r for r in results if r["ok"] is not None]
    if failures:
        lines = [f"FAIL: {len(failures)} scenario(s) failed"]
        lines += [f"  - {name}" for name in failures]
        return 1, "\n".join(lines)
    if not ran:
        return 1, "FAIL: no scenario ran, so the filter matched nothing or every match was skipped"
    return 0, "PASS: every scenario, checked against the server as well as the UI."
