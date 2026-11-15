# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A file big enough for upload sessions survives a channel switch and a dropped network.

It runs in a channel of its own, so a 40 MB message never lengthens #general
under the scenarios after it.

Alice's upload is throttled so it is still going while she switches to her
Notes and comes back, and while her network drops for a few seconds; the session
has to resume where it stopped rather than start over or give up. The file
is made in her page from a fixed pattern and hashed there, and an
attachment's id is the sha256 of the bytes the server stored, so a part sent
twice, dropped or out of order shows up as a different id. Bob then
downloads it and gets the same bytes.
"""
import hashlib
import json
import time

import e2e_api
import e2e_labels as L

SIZE = 40 * 1024 * 1024
UPLOAD_BYTES_PER_SECOND = 3_000_000
NAME = "e2e-large-upload.bin"
SEND_TIMEOUT = 120

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

# Flutter names a button by its text rather than aria-label, and a disabled one is neither tappable nor enabled.
_SEND_STATE = """(function(){
  var e=[].slice.call(document.querySelectorAll('flt-semantics')).find(function(e){
    return (e.getAttribute('aria-label') || e.textContent || '').trim() === %s; });
  if (!e) return 'missing';
  return e.hasAttribute('flt-tappable') && e.getAttribute('aria-disabled') !== 'true' ? 'ready' : 'disabled';
})()""" % json.dumps(L.SEND)


def _throttle(client, upload):
    client.send("Network.emulateNetworkConditions", {
        "offline": False, "latency": 0, "downloadThroughput": -1, "uploadThroughput": upload})


def _send_state(client):
    return client.ev(_SEND_STATE)


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
        _throttle(a, UPLOAD_BYTES_PER_SECOND)
        a.watch_for_file_input()
        a.click(L.ATTACH, settle=2)
        made = a.send("Runtime.evaluate", {
            "expression": _MAKE_FILE % (SIZE, json.dumps(NAME)),
            "awaitPromise": True, "returnByValue": True})
        assert made.get("result", {}).get("result", {}).get("value") == "ok", made
        sha = a.ev("window.__e2eMadeSha")
        a.wait_for(NAME)
        time.sleep(3)
        state = _send_state(a)
        if state != "disabled":
            a.shot("large-upload-not-uploading")
        assert state == "disabled", f"Send read {state!r} three seconds into a throttled 40 MB upload"

        a.click(L.NOTES, settle=2)
        a.click(name, settle=2)
        assert a.find(NAME), "switching channels dropped the staged upload"
        print("  switching channels mid-upload keeps the file staged and uploading")

        a.go_offline()
        time.sleep(4)
        _throttle(a, UPLOAD_BYTES_PER_SECOND)
        print("  the network dropped for four seconds mid-upload and came back")

        deadline = time.time() + SEND_TIMEOUT
        while _send_state(a) != "ready":
            assert time.time() < deadline, "the upload never finished after the network came back"
            time.sleep(0.5)
        a.go_online()
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
        a.go_online()
        for c in (a, b):
            c.click(L.TEXT_CHANNEL)
        admin.status("DELETE", f"/channels/{channel_id}")
