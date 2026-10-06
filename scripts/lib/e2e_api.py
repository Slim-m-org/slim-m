# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Ask the server what actually happened, rather than believing the screen.

Every scenario drives the UI and then checks here. A roster that renders, a
reaction chip that appears, an avatar that shows: none of those are evidence
the server stored anything, and a client that only ever agrees with itself
would pass a run where nothing was persisted at all.
"""
import json
import urllib.error
import urllib.request

import uuid7

# Every path this helper calls, so a run can report the coverage it truly had
# rather than the coverage somebody once wrote down.
TOUCHED = set()

# Cloudflare 403s ("error code: 1010") a default urllib UA; see CLAUDE.md.
USER_AGENT = "Mozilla/5.0 (compatible; slim-m-scripts/1.0)"


def _list_body(got):
    """A list endpoint sends a bare array; anything else is a wire break."""
    assert isinstance(got, list), f"expected a bare array, got {type(got).__name__}: {got!r}"
    return got


class Api:
    """One signed-in caller's view of the server."""

    def __init__(self, base, token=None):
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method, path, body=None, raw=None, content_type=None):
        headers = {"User-Agent": USER_AGENT}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        data = raw
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        if content_type:
            headers["Content-Type"] = content_type
        TOUCHED.add(path)
        req = urllib.request.Request(f"{self.base}{path}", data=data,
                                     headers=headers, method=method)
        with urllib.request.urlopen(req) as res:
            payload = res.read()
            if not payload:
                return None
            try:
                return json.loads(payload)
            except ValueError:
                return payload

    def status(self, method, path, body=None):  # noqa: D401
        """The status code alone, for the paths whose refusal is the point."""
        try:
            self.call(method, path, body)
            return 200
        except urllib.error.HTTPError as exc:
            return exc.code

    def login(self, username, password, device="e2e"):
        got = self.call("POST", "/auth/login", {
            "username": username, "password": password, "device_name": device})
        self.token = got["access_token"]
        return got

    def me(self):
        return self.call("GET", "/me")

    def channels(self):
        return self.call("GET", "/channels")

    def channel_named(self, name):
        for c in self.channels():
            if c["name"] == name:
                return c
        raise AssertionError(f"no channel named {name!r}")

    def messages(self, channel_id):
        got = self.call("GET", f"/channels/{channel_id}/messages")
        return _list_body(got)

    def message_with(self, channel_id, needle):
        for m in self.messages(channel_id):
            if needle in (m.get("content") or ""):
                return m
        raise AssertionError(f"no message containing {needle!r}")

    def send_message(self, channel_id, content, reply_to_id=None):
        """A send with a client-generated id, the way any real client sends.

        `reply_to_id` is the one field 'Reply' itself would attach through
        the context menu this harness cannot open; see e2e_replies.py.
        """
        body = {"id": uuid7.uuid7(), "content": content}
        if reply_to_id is not None:
            body["reply_to_id"] = reply_to_id
        return self.call("POST", f"/channels/{channel_id}/messages", body)

    def open_thread(self, channel_id, message_id):
        """The API substitute for 'Reply in thread'; see e2e_threads.py."""
        return self.call(
            "POST", f"/channels/{channel_id}/messages/{message_id}/thread")

    def edit_message(self, channel_id, message_id, content):
        """Rewrites a message's content, the way another device would."""
        return self.call("PATCH",
                         f"/channels/{channel_id}/messages/{message_id}",
                         {"content": content})

    def delete_message(self, channel_id, message_id):
        return self.call("DELETE",
                         f"/channels/{channel_id}/messages/{message_id}")

    def members(self):
        got = self.call("GET", "/members")
        return _list_body(got)

    def member_named(self, display_name):
        for m in self.members():
            if m.get("display_name") == display_name:
                return m
        raise AssertionError(f"no member named {display_name!r}")

    def pins(self, channel_id):
        got = self.call("GET", f"/channels/{channel_id}/pins")
        return _list_body(got)

    def reports(self):
        got = self.call("GET", "/reports")
        return _list_body(got)

    def blocks(self):
        got = self.call("GET", "/blocks")
        return _list_body(got)

    def roles(self):
        got = self.call("GET", "/roles")
        return _list_body(got)

    def space_settings(self):
        return self.call("GET", "/space/settings")

    def canvas_objects(self, channel_id, half_width=1_000_000.0):
        """Every live canvas object, well past anything this harness places."""
        q = (f"min_x=-{half_width}&min_y=-{half_width}"
             f"&max_x={half_width}&max_y={half_width}")
        got = self.call("GET", f"/channels/{channel_id}/canvas/objects?{q}")
        return got["objects"]

    def canvas_object(self, channel_id, object_id):
        for obj in self.canvas_objects(channel_id):
            if obj["id"] == object_id:
                return obj
        raise AssertionError(f"no live canvas object {object_id!r}")

    def canvas_media_slots(self, channel_id):
        got = self.call("GET", f"/channels/{channel_id}/canvas/media-slots")
        return got["slots"]

    def canvas_media_slot(self, channel_id, kind, user_id):
        """None until a drag, resize, lock or depth toggle has ever
        committed one - see CanvasMediaSlotSync's own doc for why turning a
        camera on alone writes nothing.
        """
        for slot in self.canvas_media_slots(channel_id):
            if slot["kind"] == kind and slot["user_id"] == user_id:
                return slot
        return None

    def version(self):
        return Api(self.base).call("GET", "/version")
