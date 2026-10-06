# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The contact sheet `ui_capture_report.py` writes: one page, every image,
grouped by the harness that made it, with the failures a reviewer needs to
see before trusting the set as complete right at the top.

Split out of `ui_capture_report.py` to keep manifest-building (what actually
happened) separate from how it is presented - the same split this repo
already draws elsewhere between a data source and its rendering.
"""
import html

CAVEATS = [
    (
        "The harness loads Noto Color Emoji when the machine has it. If "
        "emoji render as tofu boxes (empty rectangles) here, the font was "
        "not found on the machine that ran the capture, which the run "
        "warned about on stderr; that is a harness gap, not an app defect."
    ),
    (
        "A thin diagonal stroke can paint as broken or dotted at a low "
        "effective pixel width, even when the underlying geometry is "
        "correct; see visual_render_support.dart's own doc comment (voice_"
        "canvas package) for how this was disproved. Do not read a broken "
        "hairline here as a real gap in the ink."
    ),
]

CATEGORY_INFO = {
    "screens": {
        "title": "Screens",
        "blurb": "Resting screens, routed and rendered whole.",
        "grow": (
            "Add a route to the _surfaces (or _canvasSurfaces / "
            "_voiceCallSurfaces) table in "
            "client/packages/app/test/ui_snapshot_test.dart."
        ),
    },
    "overlays": {
        "title": "Overlays",
        "blurb": "Sheets, dialogs, popovers, and gesture-opened menus.",
        "grow": (
            "Add an entry to the _overlays table in "
            "client/packages/app/test/ui_overlay_snapshot_test.dart, or, for "
            "something only reachable by a long-press, right-click, or a "
            "multi-step interaction (typing, submitting, waiting on a "
            "mocked response), add a case to one of its sibling files: "
            "ui_overlay_snapshot_menus_test.dart (gesture-opened menus), "
            "ui_overlay_snapshot_confirm_test.dart (confirmDangerousAction "
            "variants), ui_overlay_snapshot_onboarding_test.dart (the "
            "invite dialog, the manual-server dialog, and the TOFU "
            "identity screens), ui_overlay_snapshot_signin_test.dart "
            "(sign-in probe notices and submit-path errors), ui_overlay_"
            "snapshot_moderation_test.dart (the member popover matrix), "
            "ui_overlay_snapshot_blocking_test.dart (the blocked-DM "
            "states), or ui_overlay_snapshot_reports_test.dart (report "
            "card variants)."
        ),
    },
    "canvas-assembled": {
        "title": "Canvas, assembled",
        "blurb": (
            "The dock, face-pile, self bubble and drawing surface together, "
            "with realistic content."
        ),
        "grow": (
            "Add a scene to "
            "client/packages/app/test/visual/canvas_assembled_snapshot_test.dart."
        ),
    },
    "canvas-painters": {
        "title": "Canvas painters",
        "blurb": (
            "The canvas's own paint layers with no widget tree at all: ink, "
            "shapes, notes, cursors, elevation."
        ),
        "grow": (
            "Add a scene to "
            "client/packages/voice_canvas/test/visual/canvas_visual_render.dart."
        ),
    },
}


def _e(text):
    return html.escape(str(text))


def job_failures(category, job):
    """Every reason one job leaves the set incomplete, as failure rows."""
    out = []
    if job["exit_code"] != 0 and not job["summary"]["failed"]:
        out.append(
            {
                "category": category,
                "job": job["id"],
                "name": None,
                "error": f"flutter test exited {job['exit_code']}",
            }
        )
    for test in job["summary"]["failed"]:
        out.append(
            {
                "category": category,
                "job": job["id"],
                "name": test["name"],
                "error": test.get("error") or "(no error captured)",
            }
        )
    if job["summary"]["silent_gap"]:
        out.append(
            {
                "category": category,
                "job": job["id"],
                "name": None,
                "error": (
                    f"{job['summary']['passed']} test(s) passed but "
                    "wrote zero images; the write helper silently "
                    "did not run"
                ),
            }
        )
    return out


def collect_failures(manifest):
    """Every reason the set is incomplete, flattened: a harness that would
    not run, a test that failed, or a test that passed while writing no
    image at all - the "silently missing file" shape this tool exists to
    surface rather than let hide behind a green run."""
    return [
        failure
        for category, entry in manifest["categories"].items()
        for job in entry["jobs"]
        for failure in job_failures(category, job)
    ]


def _render_failure(failure):
    label = _e(failure["name"]) if failure["name"] else "(harness-level)"
    return (
        f"<div class=failure><div class=failure-head>"
        f'<span class=badge>{_e(failure["category"])}/{_e(failure["job"])}</span> '
        f"{label}</div>"
        f"<pre>{_e(failure['error'])[:2000]}</pre></div>"
    )


def _render_category(category_id, info, entry):
    parts = [f'<section id="{category_id}"><h2>{_e(info["title"])}</h2>']
    parts.append(f'<p class=blurb>{_e(info["blurb"])}</p>')
    parts.append(f'<p class=grow>Add a state: {_e(info["grow"])}</p>')
    if entry is None:
        parts.append("<p class=empty>Not captured in this run.</p></section>")
        return "\n".join(parts)
    parts.append("<table class=jobs><tr><th>job</th><th>tests</th><th>passed</th><th>images</th></tr>")
    for job in entry["jobs"]:
        summary = job["summary"]
        ok = not job_failures(category_id, job)
        parts.append(
            f'<tr class={"ok" if ok else "bad"}><td>{_e(job["id"])}</td>'
            f'<td>{summary["total"]}</td><td>{summary["passed"]}</td>'
            f'<td>{job["images"]}</td></tr>'
        )
    parts.append("</table>")
    parts.append(f'<p class=count>{len(entry["images"])} image(s)</p>')
    parts.append("<div class=grid>")
    for name in entry["images"]:
        src = f"images/{category_id}/{name}"
        caption = name[:-4] if name.endswith(".png") else name
        parts.append(
            f'<a class=tile href="{_e(src)}" target=_blank>'
            f'<img loading=lazy src="{_e(src)}" alt="{_e(caption)}">'
            f"<span>{_e(caption)}</span></a>"
        )
    parts.append("</div></section>")
    return "\n".join(parts)


def render_html(manifest):
    parts = [
        "<!doctype html><meta charset=utf-8>",
        "<title>slim-m UI capture</title>",
        "<style>",
        _CSS,
        "</style>",
        "<h1>slim-m UI capture</h1>",
        f"<p class=meta>generated {_e(manifest['generated_at'])}</p>",
    ]
    parts.append(
        '<div class="banner ok">Every capture rendered.</div>'
        if manifest["ok"]
        else '<div class="banner bad">'
        "Something did not render. See Failures below before trusting "
        "this set as complete.</div>"
    )
    parts.append("<div class=caveats><h2>Before you judge a pixel</h2><ul>")
    for caveat in CAVEATS:
        parts.append(f"<li>{_e(caveat)}</li>")
    parts.append("</ul></div>")

    failures = collect_failures(manifest)
    if failures:
        parts.append(f"<div class=failures><h2>Failures ({len(failures)})</h2>")
        for failure in failures:
            parts.append(_render_failure(failure))
        parts.append("</div>")

    parts.append("<h2>Contents</h2><ul class=toc>")
    for category_id in CATEGORY_INFO:
        if category_id in manifest["categories"]:
            parts.append(f'<li><a href="#{category_id}">{_e(CATEGORY_INFO[category_id]["title"])}</a></li>')
    parts.append("</ul>")

    for category_id, info in CATEGORY_INFO.items():
        entry = manifest["categories"].get(category_id)
        parts.append(_render_category(category_id, info, entry))
    return "\n".join(parts)


_CSS = """
body { font-family: system-ui, sans-serif; margin: 2rem; background: #14171c; color: #e7ebf0; }
h1, h2 { font-weight: 600; }
.meta { color: #8a94a3; margin-top: -0.5rem; }
.banner { padding: 0.75rem 1rem; border-radius: 6px; margin: 1rem 0; font-weight: 600; }
.banner.ok { background: #17331f; color: #7be08f; }
.banner.bad { background: #3a1a1a; color: #ff9a9a; }
.caveats { border: 1px solid #333c47; border-radius: 6px; padding: 0.5rem 1rem; margin: 1rem 0; }
.failures { border: 1px solid #6b2222; border-radius: 6px; padding: 0.5rem 1rem; margin: 1rem 0; }
.failure { margin: 0.75rem 0; }
.failure-head { font-weight: 600; }
.failure pre { white-space: pre-wrap; background: #1c1f26; padding: 0.5rem; border-radius: 4px; max-height: 12rem; overflow: auto; }
.badge { display: inline-block; background: #2b2f38; padding: 0.1rem 0.4rem; border-radius: 4px; font-family: monospace; }
table.jobs { border-collapse: collapse; margin: 0.5rem 0 1rem; }
table.jobs th, table.jobs td { border: 1px solid #333c47; padding: 0.25rem 0.6rem; text-align: left; }
table.jobs tr.bad { background: #3a1a1a; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 0.75rem; }
.tile { color: inherit; text-decoration: none; border: 1px solid #333c47; border-radius: 6px; overflow: hidden; display: block; background: #1c1f26; }
.tile img { width: 100%; display: block; background: #0a0c0f; }
.tile span { display: block; padding: 0.3rem 0.5rem; font-size: 0.75rem; word-break: break-all; color: #b7c0cc; }
.toc { color: #8a94a3; }
.count { color: #8a94a3; }
.blurb, .grow { color: #b7c0cc; margin: 0.15rem 0; }
"""
