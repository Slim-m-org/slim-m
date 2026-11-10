# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Cold-start time and idle memory of the Flutter web client, over CDP.

There is no offscreen way to run the Linux desktop build on this box: the
Linux target links GTK, GTK needs a display connection to construct a
window, and this host has neither `Xvfb` installed nor passwordless `sudo`
to install it (checked, not assumed). So this measures the client's web
build instead, driven the same way `scripts/e2e.sh` already drives it: a
real headless `google-chrome-stable` process, addressed over the Chrome
DevTools Protocol on its `--remote-debugging-port`. Headless Chrome opens no
window on this or any display, which is what makes it a legitimate stand-in
for "no visible window on this box" rather than a workaround for it.

This is a real substitution, not the same measurement under another name.
"Cold start" here is dart2js-compiled JS plus CanvasKit/Skia WASM booting
inside V8, not the Linux GTK embedder's own native startup path, and "idle
memory" is a browser tab's resident memory (JS heap plus the WASM linear
memory backing Skia) rather than a native process's RSS. Both are read
honestly as what they are in the report this feeds, not represented as the
Linux desktop numbers the roadmap's own budget was written against.

Each measurement takes two readings, one against the app and one against
`about:blank` under the identical Chrome flags, so the app's own cost can be
told apart from headless Chrome's fixed per-process overhead the way
`docs/decisions/0008-space-analytics.md` found necessary for a server
control.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
import urllib.request

INTERACTIVE_TIMEOUT = 90
SETTLE_SECONDS = 5
_ALLOWED_URL = re.compile(
    r"^(about:blank|https?://[A-Za-z0-9.-]+(:\d+)?(/[\w./?%&=~+-]*)?)$")
FLAGS = (
    "--headless=new",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-gpu",
    "--window-size=1280,900",
    "--enable-unsafe-swiftshader",
)


def _chrome_binary():
    for name in ("google-chrome-stable", "google-chrome"):
        found = shutil.which(name)
        if found:
            return found
    raise RuntimeError("missing: google-chrome-stable")


def _pss_tree_kb(pid):
    """Sum Pss across [pid] and every descendant, in kB.

    Headless Chrome is multi-process (browser, zygote, GPU, several renderer
    helpers even against `about:blank`), and summing plain `VmRSS` across a
    process tree double, triple, or worse counts the Chrome binary, the V8
    snapshot, and every other shared-library mapping the processes hold in
    common: measured directly on this box, a bare `about:blank` idle tree
    reported 1.3 GB of summed `VmRSS`, an implausible figure for a page with
    no content. `Pss` (proportional set size, from `smaps_rollup`) divides
    each shared page's cost across the processes mapping it, which is what
    turns "the tree's memory" into a real answer rather than an inflated one.
    """
    pids = [pid]
    total = 0
    seen = set()
    while pids:
        current = pids.pop()
        if current in seen:
            continue
        seen.add(current)
        try:
            with open(f"/proc/{current}/smaps_rollup", encoding="utf-8") as fh:
                for line in fh:
                    if line.startswith("Pss:"):
                        total += int(line.split()[1])
                        break
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
        try:
            out = subprocess.run(
                ["ps", "--no-headers", "-o", "pid", "--ppid", str(current)],
                capture_output=True, text=True, check=False,
            )
            pids.extend(int(p) for p in out.stdout.split())
        except FileNotFoundError:
            pass
    return total


class _Cdp:
    """A minimal CDP client, scoped to what this probe needs.

    `scripts/lib/e2e_client.py` already drives a Flutter web app over CDP,
    but its `Client` carries screenshot/log-capture/scenario-driving state
    this probe has no use for; a second, narrower client keeps this script
    self-contained rather than coupling a perf tool to the e2e harness's own
    evolution.
    """

    def __init__(self, port):
        self.port = port
        self._ws = None
        self._id = 0

    def _connect(self):
        from websocket import create_connection
        targets = json.load(urllib.request.urlopen(
            f"http://127.0.0.1:{self.port}/json/list", timeout=10))
        page = next(t for t in targets if t["type"] == "page")
        self._ws = create_connection(
            page["webSocketDebuggerUrl"], suppress_origin=True, timeout=30)

    def send(self, method, params=None):
        if self._ws is None:
            self._connect()
        self._id += 1
        self._ws.send(json.dumps(
            {"id": self._id, "method": method, "params": params or {}}))
        while True:
            msg = json.loads(self._ws.recv())
            if msg.get("id") == self._id:
                return msg

    def ev(self, expression):
        r = self.send("Runtime.evaluate",
                       {"expression": expression, "returnByValue": True,
                        "awaitPromise": False})
        return r.get("result", {}).get("result", {}).get("value")

    def close(self):
        if self._ws is not None:
            try:
                self._ws.close()
            except OSError:
                pass


def _launch_chrome(chrome, profile_dir, port, url):
    os.makedirs(profile_dir, exist_ok=True)
    args = [chrome, *FLAGS, f"--user-data-dir={profile_dir}",
            f"--remote-debugging-port={port}", url]
    proc = subprocess.Popen(
        args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            urllib.request.urlopen(
                f"http://127.0.0.1:{port}/json/version", timeout=1)
            return proc
        except OSError:
            time.sleep(0.25)
    proc.kill()
    raise RuntimeError(f"chrome never answered on port {port}")


def _kill_chrome(proc):
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait(timeout=10)


def _wait_interactive(cdp, deadline):
    """Poll for the moment Flutter's own accessibility tree has real content.

    The same technique `scripts/lib/e2e_client.py`'s `enable_semantics`
    already uses to know the app is up: click the placeholder Flutter web
    leaves in the DOM until real `<flt-semantics>` nodes replace it, which
    only happens once the engine has booted and painted the first real
    screen (onboarding or sign-in, since this probe configures no server).
    """
    js = ("(function(){var p=document.querySelector("
          "'flt-semantics-placeholder');if(p)p.click();"
          "return document.querySelectorAll('flt-semantics').length;})()")
    while time.monotonic() < deadline:
        count = cdp.ev(js)
        if count and count > 0:
            return True
        time.sleep(0.2)
    return False


def _navigation_timing(cdp):
    raw = cdp.ev(
        "(function(){var e=performance.getEntriesByType('navigation')[0];"
        "if(!e)return null;"
        "return JSON.stringify({domContentLoaded:e.domContentLoadedEventEnd,"
        "load:e.loadEventEnd,responseEnd:e.responseEnd});})()")
    return json.loads(raw) if raw else None


def _paint_timing(cdp):
    raw = cdp.ev(
        "(function(){var out={};"
        "performance.getEntriesByType('paint').forEach(function(p){"
        "out[p.name]=p.startTime;});return JSON.stringify(out);})()")
    return json.loads(raw) if raw else {}


def _heap_kb(cdp):
    cdp.send("Performance.enable")
    r = cdp.send("Performance.getMetrics")
    metrics = {m["name"]: m["value"] for m in r.get("result", {}).get("metrics", [])}
    used = metrics.get("JSHeapUsedSize")
    return round(used / 1024) if used is not None else None


def measure_blank(chrome, work_dir, port):
    """Headless Chrome's own baseline cost, against no app at all."""
    profile = os.path.join(work_dir, f"blank-{port}")
    proc = _launch_chrome(chrome, profile, port, "about:blank")
    try:
        time.sleep(SETTLE_SECONDS)
        cdp = _Cdp(port)
        heap_kb = _heap_kb(cdp)
        cdp.close()
        pss_kb = _pss_tree_kb(proc.pid)
        return {"heap_kb": heap_kb, "pss_tree_kb": pss_kb}
    finally:
        _kill_chrome(proc)
        shutil.rmtree(profile, ignore_errors=True)


def measure_app(chrome, work_dir, port, url):
    """One cold-start run: fresh profile, fresh process, navigate to [url]."""
    profile = os.path.join(work_dir, f"app-{port}")
    t0 = time.monotonic()
    proc = _launch_chrome(chrome, profile, port, url)
    try:
        cdp = _Cdp(port)
        deadline = t0 + INTERACTIVE_TIMEOUT
        ok = _wait_interactive(cdp, deadline)
        t_interactive = time.monotonic()
        if not ok:
            raise AssertionError(
                f"app never became interactive within {INTERACTIVE_TIMEOUT}s")
        nav = _navigation_timing(cdp)
        paint = _paint_timing(cdp)
        time.sleep(SETTLE_SECONDS)
        heap_kb = _heap_kb(cdp)
        cdp.close()
        pss_kb = _pss_tree_kb(proc.pid)
        return {
            "cold_start_interactive_ms": round((t_interactive - t0) * 1000),
            "navigation_timing_ms": nav,
            "paint_timing_ms": paint,
            "heap_kb": heap_kb,
            "pss_tree_kb": pss_kb,
        }
    finally:
        _kill_chrome(proc)
        shutil.rmtree(profile, ignore_errors=True)


def _validated_url(url):
    """Refuses anything past a plain http(s) URL or `about:blank`.

    [url] reaches `subprocess.Popen` as one of Chrome's own arguments, and
    a security scanner flags any command-line-derived string reaching a
    process launch as a tainted sink regardless of `Popen` taking a list
    rather than a shell string (which is already immune to shell
    injection). Validating here, once, at the boundary this value crosses
    from caller input into a launched process, is the actual guard: a
    caller passing anything else gets a refusal naming the value.
    """
    if not _ALLOWED_URL.match(url):
        raise ValueError(f"refusing to launch chrome against {url!r}")
    return url


def run(url, runs, base_port=9820):
    url = _validated_url(url)
    chrome = _chrome_binary()
    work_dir = tempfile.mkdtemp(prefix="client-startup-probe-")
    try:
        results = []
        for i in range(runs):
            port = base_port + i
            app = measure_app(chrome, work_dir, port, url)
            blank = measure_blank(chrome, work_dir, port)
            app["baseline_heap_kb"] = blank["heap_kb"]
            app["baseline_pss_tree_kb"] = blank["pss_tree_kb"]
            if app["heap_kb"] is not None and blank["heap_kb"] is not None:
                app["heap_over_baseline_kb"] = app["heap_kb"] - blank["heap_kb"]
            if app["pss_tree_kb"] is not None and blank["pss_tree_kb"] is not None:
                app["pss_over_baseline_kb"] = (
                    app["pss_tree_kb"] - blank["pss_tree_kb"])
            results.append(app)
        return results
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    import sys
    target_url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8357"
    run_count = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    print(json.dumps(run(target_url, run_count), indent=2))
