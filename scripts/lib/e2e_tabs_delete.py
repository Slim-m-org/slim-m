# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A message deleted while one of an account's two tabs is held up.

Two tabs share one local database but each keeps its own socket and its own
memory of what it deleted. A tab that falls behind (the browser freezes a
background tab, a long task blocks it) is handed everything its socket received
once it runs again, so it replays a message being created and then deleted
after the other tab applied both. It must not store the message again: the
delete is behind the shared op cursor by then and is skipped, which would leave
the message standing in both tabs.

The tab is held with the debugger rather than the lifecycle freeze, which a
headless tab does not honour: its script stops, its socket keeps receiving.
"""
import json
import os
import time
import urllib.request

import e2e_api
import e2e_browsers
import e2e_labels as L
import e2e_session
from e2e_client import Client

PASSWORD = "tabs-delete-pass-e2e-1"
ANCHOR = "both tabs see this one"
DOOMED = "sent and deleted while a tab was held up"
# Long enough for the held tab to replay its frames and both transcripts to repaint.
SETTLE_SECONDS = 8


def _open_second_tab(first):
    url = first.ev("location.href")
    req = urllib.request.Request(
        f"http://127.0.0.1:{first.port}/json/new?about:blank", method="PUT")
    with e2e_api.urlopen(req) as resp:
        target = json.load(resp)["id"]
    second = Client("tab-b", first.port, target=target)
    second.send("Page.enable")
    second.send("Page.navigate", {"url": url})
    second.enable_semantics()
    return second


def _front(tab):
    tab.send("Page.bringToFront")
    time.sleep(0.5)


def _hold(tab):
    """Stops the tab's script at its next statement; its socket still fills."""
    tab.send("Debugger.enable")
    tab.send("Debugger.pause")


def _let_go(tab):
    resumed = tab.send("Debugger.resume")
    tab.send("Debugger.disable")
    # Resume is refused unless the script had stopped, which is the whole premise.
    assert "error" not in resumed, f"{tab.name} was never held: {resumed['error']}"


def _open_channel(tab):
    _front(tab)
    tab.click(L.TEXT_CHANNEL)
    tab.wait_for(L.COMPOSER)


def _gone_from(tab, text, timeout=20):
    deadline = time.time() + timeout
    while tab.find(text):
        assert time.time() < deadline, f"{tab.name} still shows the deleted message"
        time.sleep(0.25)


def _stays_gone(tab, text, seconds):
    _front(tab)
    deadline = time.time() + seconds
    while time.time() < deadline:
        if tab.find(text):
            tab.shot(f"deleted-message-came-back-{tab.name}")
            raise AssertionError(
                f"{tab.name} shows a deleted message again after the other tab caught up")
        time.sleep(0.25)


def a_held_tab_does_not_bring_back_a_deleted_message(server, admin, sign_in):
    username, _ = e2e_session.register_member(server, admin, PASSWORD)
    channel_id = admin.channel_named(L.TEXT_CHANNEL)["id"]
    wav = os.path.join(e2e_browsers.work_dir(), "fake-voice.wav")
    with e2e_browsers.browser("tabs", wav) as first:
        sign_in(first, server, username, PASSWORD)
        e2e_browsers.dismiss_welcome(first)
        second = _open_second_tab(first)
        for tab in (second, first):
            _open_channel(tab)
        admin.send_message(channel_id, ANCHOR)
        for tab in (second, first):
            _front(tab)
            tab.wait_for(ANCHOR)

        _front(first)
        _hold(second)
        try:
            doomed = admin.send_message(channel_id, DOOMED)
            first.wait_for(DOOMED)
            admin.delete_message(channel_id, doomed["id"])
            _gone_from(first, DOOMED)
            print("  the live tab saw the message arrive and go")
        finally:
            _let_go(second)

        _stays_gone(second, DOOMED, SETTLE_SECONDS)
        _stays_gone(first, DOOMED, SETTLE_SECONDS)
        # A reload reads the shared database, not what either tab had on screen.
        first.send("Page.reload", {})
        time.sleep(4)
        first.enable_semantics()
        _open_channel(first)
        first.wait_for(ANCHOR)
        _stays_gone(first, DOOMED, 3)
        print("  the held tab replayed both frames and the message stayed gone")
