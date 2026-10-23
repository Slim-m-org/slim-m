# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Two tabs of one account, past access-token expiry, rotating in turn.

Each tab keeps its own copy of the token pair, so a tab that rotates leaves the
other on a refresh token the server has spent, and the server reads its next
refresh as theft and signs both out. The access token lives 15 minutes and the
server has no knob for that, so expiry is forced: the page's next
authenticated request is sent with a bad token, which is what an expired one
looks like to the server. Storage events are held back from the tabs so each
keeps the pair it loaded, which is the race the cross-tab lock exists for.
"""
import json
import os
import time
import urllib.request

import e2e_browsers
import e2e_labels as L
import e2e_session
from e2e_client import Client

ROUNDS = 3
PASSWORD = "tabs-pass-for-e2e-1"

# Counts refresh calls and spoils the Authorization header of the next n authenticated requests.
HOOK = """(function () {
  if (window.__tabs) return;
  var t = window.__tabs = {n: 0, spoiled: 0, refreshes: 0, block: true, events: 0, sent: []};
  // Keeps this tab on the pair it loaded, as in the instant both tabs' access tokens lapse together.
  window.addEventListener('storage', function (e) {
    t.events++;
    if (t.block) e.stopImmediatePropagation();
  }, true);
  function spoil(url, value) {
    if (/auth\\/(refresh|login)/.test(url)) return value;
    if (t.n > 0) { t.n--; t.spoiled++; return 'Bearer expired'; }
    return value;
  }
  var open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, u) {
    this.__u = String(u);
    if (/auth\\/refresh/.test(this.__u)) t.refreshes++;
    return open.apply(this, arguments);
  };
  var send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function (body) {
    if (/auth\\/refresh/.test(this.__u)) {
      try {
        var text = typeof body === 'string' ? body : new TextDecoder().decode(body);
        t.sent.push(JSON.parse(text).refresh_token.slice(-6));
      } catch (e) { t.sent.push('?' + typeof body); }
    }
    return send.apply(this, arguments);
  };
  var set = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.setRequestHeader = function (k, v) {
    if (String(k).toLowerCase() === 'authorization') v = spoil(this.__u, v);
    return set.call(this, k, v);
  };
  var f = window.fetch;
  window.fetch = function (input, init) {
    var url = String(input && input.url || input);
    if (/auth\\/refresh/.test(url)) {
      t.refreshes++;
      try {
        var raw = init && init.body;
        var text = typeof raw === 'string' ? raw : new TextDecoder().decode(raw);
        t.sent.push(JSON.parse(text).refresh_token.slice(-6));
      } catch (e) { t.sent.push('?'); }
    }
    var h = init && init.headers;
    if (h && !(h instanceof Headers)) h = new Headers(h);
    if (h && h.has('authorization')) {
      h.set('authorization', spoil(url, h.get('authorization')));
      init = Object.assign({}, init, {headers: h});
    }
    return f.call(this, input, init);
  };
})()"""


def _install_hook(tab):
    """Runs the hook before the app boots, so its listeners come first."""
    tab.send("Page.enable")
    tab.send("Page.addScriptToEvaluateOnNewDocument", {"source": HOOK})


def _open_second_tab(first):
    url = first.ev("location.href")
    req = urllib.request.Request(
        f"http://127.0.0.1:{first.port}/json/new?about:blank", method="PUT")
    with urllib.request.urlopen(req) as resp:
        target = json.load(resp)["id"]
    second = Client("tab-b", first.port, target=target)
    _install_hook(second)
    second.send("Page.navigate", {"url": url})
    second.enable_semantics()
    return second


def _state(tab):
    return tab.ev("JSON.stringify(window.__tabs || null)")


def _count(tab, key):
    return json.loads(_state(tab))[key]


def _front(tab):
    tab.send("Page.bringToFront")
    time.sleep(0.5)


def _use_account_pane(tab):
    """Opens a screen that asks the server something, so the spoiled token is sent."""
    _front(tab)
    tab.click(L.PERSONAL_SETTINGS, settle=2)
    tab.click(L.ACCOUNT_PANE, settle=2)
    tab.click(L.BACK_TO_CHANNELS, settle=2)


def _wait(tab, key, at_least, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _count(tab, key) >= at_least:
            return
        time.sleep(0.25)
    raise AssertionError(f"{tab.name}: {key} never reached {at_least}: {_state(tab)}")


def _signed_in(tab):
    return "#/channels" in (tab.ev("location.href") or "")


def _expire_and_use(tab):
    spoiled = _count(tab, "spoiled")
    tab.ev("window.__tabs.n = 1")
    _use_account_pane(tab)
    _wait(tab, "spoiled", spoiled + 1)
    time.sleep(3)


def _expire_and_use_or_report(tab, number):
    try:
        _expire_and_use(tab)
    except AssertionError:
        if _signed_in(tab):
            raise
        raise AssertionError(
            f"round {number}: {tab.name} was signed out: {_state(tab)}")


def two_tabs_survive_rotations(server, admin, sign_in):
    username, _ = e2e_session.register_member(server, admin, PASSWORD)
    wav = os.path.join(e2e_browsers.work_dir(), "fake-voice.wav")
    with e2e_browsers.browser("tabs", wav) as first:
        sign_in(first, server, username, PASSWORD)
        e2e_browsers.dismiss_welcome(first)
        _install_hook(first)
        first.send("Page.reload", {})
        time.sleep(3)
        first.enable_semantics()
        assert _state(first) != "null", "the hook never ran in the first tab"
        second = _open_second_tab(first)
        tabs = (first, second)
        for number in range(ROUNDS):
            lead, follow = tabs if number % 2 == 0 else tabs[::-1]
            for tab in (lead, follow):
                _expire_and_use_or_report(tab, number + 1)
            for tab in tabs:
                _front(tab)
                assert _signed_in(tab), (
                    f"round {number + 1}: {tab.name} was signed out: {_state(tab)}")
                tab.shot(f"tabs-round-{number + 1}-{tab.name}")
            print(f"  round {number + 1}: both tabs still signed in "
                  f"{[_state(tab) for tab in tabs]}")
        rotations = sum(_count(tab, "refreshes") for tab in tabs)
        assert rotations == ROUNDS, (
            f"expected one rotation per round, saw {rotations}: "
            f"{[_state(tab) for tab in tabs]}")
