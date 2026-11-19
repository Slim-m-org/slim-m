# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The YouTube host page's own script, run under node against a stand-in IFrame API.

The page lives as a Dart string in youtube_host_page.dart and no Dart test can
run its JavaScript, so this one pulls the script out and drives `window.slimm`
the way the app does.
"""
import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path

PAGE = (
    Path(__file__).resolve().parents[2]
    / "client/packages/app/lib/src/features/video/providers/youtube_host_page.dart"
)

_NODE = shutil.which("node")

_FAKE_YT = r"""
var vm = require('vm');
var calls = [];
var players = [];
function Player(el, opts) {
  this.opts = opts;
  players.push(this);
  calls.push(['create', opts.videoId, opts.playerVars.start]);
}
Player.prototype.playVideo = function () { calls.push(['play']); };
Player.prototype.pauseVideo = function () { calls.push(['pause']); };
Player.prototype.loadVideoById = function (o) { calls.push(['loadById', o.videoId, o.startSeconds]); };
Player.prototype.getCurrentTime = function () { return 0; };
Player.prototype.getDuration = function () { return 0; };
var sandbox = {
  setInterval: function () { return 1; },
  clearInterval: function () {},
  JSON: JSON,
  Math: Math,
  document: {
    head: {appendChild: function () {}},
    createElement: function () { return {}; },
  },
  SlimmPlayer: {postMessage: function () {}},
};
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(PAGE_SCRIPT, sandbox);
function apiReady() { sandbox.YT = {Player: Player}; sandbox.onYouTubeIframeAPIReady(); }
function ready() { players[players.length - 1].opts.events.onReady(); }
STEPS
process.stdout.write(JSON.stringify(calls));
"""


def _page_script():
    source = PAGE.read_text()
    consts = dict(re.findall(r"^const (k\w+) = '([^']*)';", source, re.M))
    html = re.search(r"youtubeHostHtml =\s*'''\n(.*?)''';", source, re.S).group(1)
    html = re.sub(r"\$(k\w+)", lambda m: consts[m.group(1)], html)
    return re.search(r"<script>\n(.*?)</script>", html, re.S).group(1)


def _run(steps):
    program = _FAKE_YT.replace("PAGE_SCRIPT", json.dumps(_page_script()))
    program = program.replace("STEPS", steps)
    out = subprocess.run(
        [_NODE, "-e", program], capture_output=True, text=True, check=True
    )
    return json.loads(out.stdout)


@unittest.skipUnless(_NODE, "node runs the page's script")
class HostPageTest(unittest.TestCase):
    def test_a_load_before_the_api_waits_for_it(self):
        calls = _run("sandbox.slimm.load('aaaaaaaaaaa', 12); apiReady(); ready();")
        self.assertEqual(calls, [["create", "aaaaaaaaaaa", 12], ["play"]])

    def test_a_second_video_before_the_first_is_ready_is_the_one_that_plays(self):
        calls = _run(
            "apiReady(); sandbox.slimm.load('aaaaaaaaaaa', 0);"
            " sandbox.slimm.load('bbbbbbbbbbb', 30); ready();"
        )
        self.assertEqual(
            calls, [["create", "aaaaaaaaaaa", 0], ["loadById", "bbbbbbbbbbb", 30]]
        )

    def test_a_load_once_ready_replaces_the_video(self):
        calls = _run(
            "apiReady(); sandbox.slimm.load('aaaaaaaaaaa', 0); ready();"
            " sandbox.slimm.load('bbbbbbbbbbb', 5);"
        )
        self.assertEqual(
            calls,
            [["create", "aaaaaaaaaaa", 0], ["play"], ["loadById", "bbbbbbbbbbb", 5]],
        )


if __name__ == "__main__":
    unittest.main()
