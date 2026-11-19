// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The page every native webview host loads: YouTube's official IFrame
/// player on youtube-nocookie.com, driven by `window.slimm` commands, with
/// its events posted back through whichever bridge the host provides.
library;

/// The origin the host page is served from. YouTube refuses an embed with no
/// HTTP Referer (errors 152/153), and in a webview the referrer must be the
/// app's own id as an https origin.
const kYoutubeHostOrigin = 'https://top.npcserver.slimm';

/// Where a host serves [youtubeHostHtml]; its directory is the base URL.
const kYoutubeHostUrl = '$kYoutubeHostOrigin/youtube_host.html';

/// The JavaScript channel webview_flutter exposes to the page.
const kYoutubeBridgeName = 'SlimmPlayer';

/// Each event is one JSON object: `{"event": "host" | "ready" | "state" |
/// "time" | "error", ...}`. `state` carries `s` (the IFrame API's
/// PlayerState number), `time` carries `t` and `d` in seconds, `error`
/// carries `code`. The native hosts add `fullscreen` with `on`.
const youtubeHostHtml =
    '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="strict-origin-when-cross-origin">
<style>
html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
#player { position: absolute; inset: 0; width: 100%; height: 100%; }
</style>
</head>
<body>
<div id="player"></div>
<script>
(function () {
  var origin = '$kYoutubeHostOrigin';
  var player = null;
  var ready = false;
  var pending = null;
  var ticker = null;

  function send(message) {
    var text = JSON.stringify(message);
    if (window.$kYoutubeBridgeName && window.$kYoutubeBridgeName.postMessage) {
      window.$kYoutubeBridgeName.postMessage(text);
    } else if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.slimm) {
      window.webkit.messageHandlers.slimm.postMessage(text);
    } else if (window.chrome && window.chrome.webview) {
      window.chrome.webview.postMessage(text);
    }
  }

  function sendTime() {
    if (!player || !ready || !player.getCurrentTime) return;
    send({ event: 'time', t: player.getCurrentTime() || 0, d: player.getDuration() || 0 });
  }

  function onState(e) {
    send({ event: 'state', s: e.data });
    sendTime();
    if (e.data === 1) {
      if (!ticker) ticker = setInterval(sendTime, 500);
    } else if (ticker) {
      clearInterval(ticker);
      ticker = null;
    }
  }

  function create(id, start) {
    player = new YT.Player('player', {
      host: 'https://www.youtube-nocookie.com',
      videoId: id,
      width: '100%',
      height: '100%',
      playerVars: {
        autoplay: 1, playsinline: 1, enablejsapi: 1, rel: 0, fs: 1,
        start: Math.floor(start), origin: origin, widget_referrer: origin
      },
      events: {
        onReady: function () { ready = true; send({ event: 'ready' }); player.playVideo(); },
        onStateChange: onState,
        onError: function (e) { send({ event: 'error', code: e.data }); }
      }
    });
  }

  window.slimm = {
    load: function (id, start) {
      if (!window.YT || !window.YT.Player) { pending = [id, start]; return; }
      if (player && ready) {
        player.loadVideoById({ videoId: id, startSeconds: start });
      } else if (!player) {
        create(id, start);
      }
    },
    play: function () { if (player && ready) player.playVideo(); },
    pause: function () { if (player && ready) player.pauseVideo(); },
    seek: function (s) { if (player && ready) { player.seekTo(s, true); sendTime(); } },
    exitFullscreen: function () {
      if (document.fullscreenElement) document.exitFullscreen();
      else if (document.webkitFullscreenElement) document.webkitExitFullscreen();
    }
  };

  window.onYouTubeIframeAPIReady = function () {
    send({ event: 'api' });
    if (pending) { var p = pending; pending = null; window.slimm.load(p[0], p[1]); }
  };

  var tag = document.createElement('script');
  tag.src = 'https://www.youtube.com/iframe_api';
  tag.onerror = function () { send({ event: 'error', code: -1 }); };
  document.head.appendChild(tag);
  send({ event: 'host' });
})();
</script>
</body>
</html>
''';
