# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A file big enough for upload sessions survives a channel switch and a dropped network.

It runs in a channel of its own, so a 40 MB message never lengthens #general
under the scenarios after it.

Alice's second part is held in her browser, so the upload is still going
while she switches to her Notes and comes back; her network then drops and
fails that part, and the session has to resume where it stopped rather than
start over or give up. Holding a part, rather than throttling the network,
keeps the upload going however fast the runner's network or slow its page. The file
is made in her page from a fixed pattern and hashed there, and an
attachment's id is the sha256 of the bytes the server stored, so a part sent
twice, dropped or out of order shows up as a different id. Bob then
downloads it and gets the same bytes.
"""
import hashlib
import json
import re
import time

import e2e_api
import e2e_client
import e2e_labels as L

SIZE = 40 * 1024 * 1024
NAME = "e2e-large-upload.bin"
SEND_TIMEOUT = 120
DROP_SECONDS = 4
_UPLOAD_REQUESTS = "*/attachments/uploads/*"

# Each byte is the top byte of i * 2654435761 (Knuth's multiplier), so any shifted or repeated part changes the hash.
_MAKE_FILE = """
(async function(size, name){
  var inputs=(window.__e2eFiles||[]).filter(function(e){ return e.type === 'file'; });
  if (!inputs.length) return 'no file input was created';
  var bytes = new Uint8Array(size);
  for (var i = 0; i < size; i++) bytes[i] = Math.imul(i, 2654435761) >>> 24;
  var digest = await crypto.subtle.digest('SHA-256', bytes);
  window.__e2eMadeSha = Array.from(new Uint8Array(digest))
      .map(function(b){ return b.toString(16).padStart(2, '0'); }).join('');
  inputs.forEach(function(el){
    var dt = new DataTransfer();
    dt.items.add(new File([bytes], name, {type: 'application/octet-stream'}));
    el.files = dt.files;
    el.dispatchEvent(new Event('change', {bubbles: true}));
    el.dispatchEvent(new Event('input', {bubbles: true}));
  });
  return 'ok';
})(%d, %s)"""

# Flutter names a button by its text, one line per label and joined tooltip; a disabled one is neither tappable nor enabled.
_SEND_STATE = """(function(){
  var e=[].slice.call(document.querySelectorAll('flt-semantics')).find(function(e){
    return (e.getAttribute('aria-label') || e.textContent || '').split('\\n').some(function(line){
      return line.trim() === %s; }); });
  if (!e) return 'missing';
  return e.hasAttribute('flt-tappable') && e.getAttribute('aria-disabled') !== 'true' ? 'ready' : 'disabled';
})()""" % json.dumps(L.SEND)


def _send_state(client):
    return client.ev(_SEND_STATE)


_PART = re.compile(r"/attachments/uploads/([^/?]+)\?(?:.*&)?offset=(\d+)")


def is_later_part(request):
    """Whether a paused request sends a part past the file's first byte."""
    found = _PART.search(request["url"])
    return request["method"] == "PUT" and found is not None and int(found.group(2)) > 0


def _take_paused(client):
    paused, client.paused_requests = client.paused_requests, []
    return paused


def _hold_a_later_part(client):
    """Lets the upload's requests through until it sends a part past byte 0, and holds that one.

    Fetch has to be on before the file is staged: unthrottled, the whole upload can finish in the time it takes to see the chip.
    """
    deadline = time.time() + SEND_TIMEOUT
    let_through = []
    while time.time() < deadline:
        for paused in _take_paused(client):
            if is_later_part(paused["request"]):
                return paused["requestId"]
            client.send("Fetch.continueRequest", {"requestId": paused["requestId"]})
            let_through.append(f"{paused['request']['method']} {paused['request']['url']}")
        # Paused requests arrive as events, which only a round trip reads.
        client.ev("0")
        time.sleep(0.25)
    raise AssertionError(f"the upload never sent a part past its first; let through: {let_through}")


def _drop_network_under(client, held):
    """Cuts the network and fails the held part the way the cut does, then stops holding requests."""
    client.go_offline()
    client.send("Fetch.failRequest", {"requestId": held, "errorReason": "InternetDisconnected"})
    for paused in _take_paused(client):
        client.send("Fetch.continueRequest", {"requestId": paused["requestId"]})
    client.send("Fetch.disable")


def upload_parts(urls):
    """`{session id: sorted part offsets}` among the request `urls`."""
    parts = {}
    for url in urls:
        found = _PART.search(url)
        if found:
            parts.setdefault(found.group(1), set()).add(int(found.group(2)))
    return {sid: sorted(offsets) for sid, offsets in parts.items()}


def resume_problem(before_drop, after_drop):
    """Why the parts sent around a network drop are not one session resuming, or None."""
    sessions = upload_parts(before_drop | after_drop)
    if len(sessions) != 1:
        return f"{len(sessions)} upload sessions: {sorted(sessions)}"
    later = [o for offsets in upload_parts(after_drop).values() for o in offsets]
    if not later:
        return "no part was sent after the drop"
    if min(later) == 0:
        return "the upload started over from byte 0 after the drop"
    return None


def _download(member, attachment_id):
    req = e2e_api.urllib.request.Request(
        f"{member.base}/attachments/{attachment_id}",
        headers={"User-Agent": e2e_api.USER_AGENT, "Authorization": f"Bearer {member.token}"})
    digest = hashlib.sha256()
    with e2e_api.urlopen(req, timeout=120) as res:
        for chunk in iter(lambda: res.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def large_file_survives_a_switch_and_a_dropped_network(a, b, admin, member):
    name = f"e2e-upload-{int(time.time()) % 100000}"
    channel_id = admin.call("POST", "/channels", {"name": name, "kind": "text"})["id"]
    before = set()
    a.wait_for(name)
    a.click(name)
    b.wait_for(name)
    b.click(name)
    try:
        a.send("Fetch.enable", {"patterns": [{"urlPattern": _UPLOAD_REQUESTS}]})
        a.watch_for_file_input()
        a.click(L.ATTACH, settle=2)
        made = a.send("Runtime.evaluate", {
            "expression": _MAKE_FILE % (SIZE, json.dumps(NAME)),
            "awaitPromise": True, "returnByValue": True})
        assert made.get("result", {}).get("result", {}).get("value") == "ok", made
        sha = a.ev("window.__e2eMadeSha")
        a.wait_for(NAME)
        held = _hold_a_later_part(a)
        state = _send_state(a)
        assert state == "disabled", f"Send read {state!r} with a part of the upload still to go"
        a.click(L.NOTES, settle=2)
        a.click(name, settle=2)
        assert a.find(NAME), "switching channels dropped the staged upload"
        state = _send_state(a)
        assert state == "disabled", f"Send read {state!r} after the switch, with a part still to go"
        before_drop = set(e2e_client.REQUEST_URLS)
        _drop_network_under(a, held)
        time.sleep(DROP_SECONDS)
        a.go_online()

        deadline = time.time() + SEND_TIMEOUT
        while _send_state(a) != "ready":
            assert time.time() < deadline, "the upload never finished after the network came back"
            time.sleep(0.5)
        why = resume_problem(before_drop, set(e2e_client.REQUEST_URLS) - before_drop)
        assert why is None, f"the upload did not resume after the drop: {why}"
        print("  a channel switch and a four-second network drop mid-upload, "
              "and the one session resumed where it stopped")
        a.click(L.SEND, settle=3)

        deadline = time.time() + 30
        while True:
            fresh = [m for m in admin.messages(channel_id)
                     if m["id"] not in before and m.get("attachments")]
            if fresh:
                break
            assert time.time() < deadline, "the message with the file never arrived"
            time.sleep(0.5)
        (stored,) = fresh[-1]["attachments"]
        assert stored["size"] == SIZE, stored
        assert stored["id"] == sha, f"the server stored other bytes: {stored['id']} != {sha}"
        b.wait_for(NAME)
        assert _download(member, stored["id"]) == sha, "bob downloaded different bytes"
        b.shot("large-upload-received")
        print(f"  the 40 MB file arrived whole (sha256 {sha[:12]}), and bob downloads the same bytes")
    finally:
        a.send("Fetch.disable")
        a.go_online()
        for c in (a, b):
            c.click(L.TEXT_CHANNEL)
        admin.status("DELETE", f"/channels/{channel_id}")
