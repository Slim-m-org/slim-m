# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Deliberate edge-case probes against a channel's canvas surface.

This is the "integration test in disguise" half of canvas seeding: each
probe names an expected response and records whether the server actually
gave it, so a run's report can distinguish a documented ceiling working as
designed from something that broke, is awkward, or is missing entirely.
Nothing here is fatal - an unexpected answer is recorded as a finding, not
an exception, so one surprising probe does not abort the rest of the run.
"""
import urllib.error

import uuid7

import seed_canvas_geometry as geom
import seed_canvas_ops as ops


def _status(callable_):
    """Runs `callable_`, returning `(status, body_or_detail)`.

    `status` is `None` on success: `Api.call` never surfaces the real 2xx
    code, only the parsed body, so a probe expecting success compares
    against `None` rather than a code this helper cannot actually see.
    """
    try:
        body = callable_()
        return None, body
    except urllib.error.HTTPError as exc:
        try:
            detail = exc.read().decode(errors="replace")[:200]
        except Exception:  # noqa: BLE001 - the body is a bonus, not the point
            detail = ""
        return exc.code, detail


def _finding(name, expected, actual, detail=""):
    ok = actual == expected
    return {"name": name, "expected": expected, "actual": actual, "ok": ok,
            "detail": detail}


def run(admin_api, member_api, channel_id, sample_object):
    """Runs every probe and returns a list of finding dicts.

    `sample_object` is any still-live `CanvasObject` dict this run placed,
    used as a legitimate target for the probes that need one to exist.
    """
    findings = [
        _oversized_props(admin_api, channel_id),
        _oversized_body(admin_api, channel_id),
        _over_extent_placement(admin_api, channel_id),
        _move_nonexistent_object(admin_api, channel_id),
        _remove_empty_object_ids(admin_api, channel_id),
        _restore_targeting_a_place_op(admin_api, channel_id),
        _replay_shows_no_fresh_flag(admin_api, channel_id, sample_object),
    ]
    if member_api is not None:
        findings.append(_clear_without_manage_canvas(member_api, channel_id))
    return findings


def _oversized_props(api, channel_id):
    """Just over `MAX_PROPS_BYTES` (4 KiB) but the whole request body stays
    well under `MAX_BODY_BYTES` (8 KiB), so this is the props ceiling alone,
    not the coarser body-level one `_oversized_body` checks separately -
    the two ceilings are easy to conflate, since a naive over-large
    payload usually trips the body limit first (see that probe's own
    finding) and never actually reaches the props check this one confirms.
    """
    huge = geom.quantize(
        [(float(i) * 3300.7, float(i % 37) * 2100.3) for i in range(250)])
    placement = {"id": uuid7.uuid7(), "kind": "stroke", "x": 0, "y": 0,
                 "w": 10, "h": 10,
                 "props": {"points": [c for p in huge for c in p],
                           "width": 3.0, "color": "annotation"}}
    status, detail = _status(
        lambda: api.call("POST", f"/channels/{channel_id}/canvas/objects",
                          placement))
    return _finding("place with props just over MAX_PROPS_BYTES", 400, status,
                     detail)


def _oversized_body(api, channel_id):
    """Well past `MAX_BODY_BYTES` (8 KiB) altogether - refused at the byte
    level before serde ever builds a `Value`, per canvas.rs's own doc."""
    huge = geom.quantize(
        [(float(i), float(i % 37)) for i in range(2200)])
    placement = {"id": uuid7.uuid7(), "kind": "stroke", "x": 0, "y": 0,
                 "w": 10, "h": 10,
                 "props": {"points": [c for p in huge for c in p],
                           "width": 3.0, "color": "annotation"}}
    status, detail = _status(
        lambda: api.call("POST", f"/channels/{channel_id}/canvas/objects",
                          placement))
    return _finding("place with a request body over MAX_BODY_BYTES", 413,
                     status, detail)


def _over_extent_placement(api, channel_id):
    placement = {"id": uuid7.uuid7(), "kind": "stroke", "x": 0, "y": 0,
                 "w": 20000, "h": 20000,
                 "props": {"points": [0, 0, 1, 1], "width": 3.0,
                           "color": "annotation"}}
    status, detail = _status(
        lambda: api.call("POST", f"/channels/{channel_id}/canvas/objects",
                          placement))
    return _finding("place past MAX_OBJECT_EXTENT", 400, status, detail)


def _move_nonexistent_object(api, channel_id):
    status, detail = _status(lambda: ops.move(
        api, channel_id, uuid7.uuid7(), uuid7.uuid7(), 0, 0, 10, 10))
    return _finding("move an object id nobody placed", 404, status, detail)


def _remove_empty_object_ids(api, channel_id):
    status, detail = _status(
        lambda: api.call(
            "POST", f"/channels/{channel_id}/canvas/ops",
            {"id": uuid7.uuid7(), "kind": "remove", "object_ids": []}))
    return _finding("remove with an empty object_ids list", 400, status, detail)


def _restore_targeting_a_place_op(api, channel_id):
    page = ops.ops_page(api, channel_id, after_seq=0, limit=200)
    place_op = next((op for op in page["ops"] if op["kind"] == "place"), None)
    if place_op is None:
        return _finding("restore targeting a place op", None, None,
                         "no place op found on this page to target")
    status, detail = _status(lambda: ops.restore(
        api, channel_id, uuid7.uuid7(), place_op["id"]))
    return _finding("restore targeting a place op (not remove/clear)",
                     404, status, detail)


def _replay_shows_no_fresh_flag(api, channel_id, sample_object):
    """Replaying an already-placed id's exact body answers 201 again with
    the stored row - there is no `fresh` field on `CanvasObject` the way
    `CanvasOpResult` carries one, so a caller cannot tell a genuine
    creation from an idempotent replay without comparing fields itself."""
    placement = {"id": sample_object["id"], "kind": sample_object["kind"],
                 "x": sample_object["x"], "y": sample_object["y"],
                 "w": sample_object["w"], "h": sample_object["h"],
                 "props": sample_object["props"]}
    status, body = _status(
        lambda: api.call("POST", f"/channels/{channel_id}/canvas/objects",
                          placement))
    same_seq = isinstance(body, dict) and body.get("seq") == sample_object["seq"]
    finding = _finding("replay an existing placement id", None, status)
    finding["detail"] = (
        "same seq came back and no 'fresh' flag exists to confirm this "
        "was a replay rather than a new write" if same_seq else
        "replay did not return the original seq")
    finding["ok"] = status is None and same_seq
    return finding


def _clear_without_manage_canvas(member_api, channel_id):
    status, detail = _status(lambda: ops.clear(
        member_api, channel_id, uuid7.uuid7(), 1))
    return _finding("clear without MANAGE_CANVAS", 403, status, detail)
