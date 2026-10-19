# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The in-page half of the join-time measurement.

Runs after e2e_audio_js.PROBE, in the same document, and stamps the stages of
one voice join on the page's own clock so no CDP round trip skews them. The
Python side arms it, taps, and reads the stamps back once audio has arrived.
"""

PROBE = r"""
(function(){
  if (window.__joinMarks) return;
  var M = {armed: false, m: {}, pcs: []};
  window.__joinMarks = M;
  function stamp(name, at){
    if (M.armed && M.m[name] === undefined) M.m[name] = at === undefined ? performance.now() : at;
  }
  M.arm = function(){ M.armed = true; M.m = {}; M.pcs = []; M.mark = performance.now(); };
  window.addEventListener('pointerup', function(){ stamp('click'); }, true);

  var WS = window.WebSocket;
  window.WebSocket = new Proxy(WS, {
    construct: function(target, args, newTarget){
      var ws = Reflect.construct(target, args, newTarget);
      if (M.armed && String(args[0]).indexOf('/rtc') >= 0) {
        stamp('wsStart');
        ws.addEventListener('open', function(){ stamp('wsOpen'); });
      }
      return ws;
    }
  });

  var gum = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
  navigator.mediaDevices.getUserMedia = function(c){
    var audio = c && c.audio;
    if (M.armed && audio) stamp('micRequested');
    var p = gum(c);
    if (audio) p.then(function(){ stamp('micOpened'); }, function(){});
    return p;
  };

  var addT = RTCPeerConnection.prototype.addTransceiver;
  RTCPeerConnection.prototype.addTransceiver = function(trackOrKind, init){
    var pc = this;
    var isAudio = trackOrKind === 'audio' ||
      (trackOrKind && trackOrKind.kind === 'audio');
    var sending = init && init.direction === 'sendonly';
    if (M.armed && isAudio && sending) {
      stamp('publishStart');
      var onState = function(){
        if (pc.signalingState === 'stable' && M.m.publishStart !== undefined) {
          stamp('published');
          pc.removeEventListener('signalingstatechange', onState);
        }
      };
      pc.addEventListener('signalingstatechange', onState);
    }
    return addT.apply(this, arguments);
  };

  var Orig = window.RTCPeerConnection;
  window.RTCPeerConnection = new Proxy(Orig, {
    construct: function(target, args, newTarget){
      var pc = Reflect.construct(target, args, newTarget);
      if (!M.armed) return pc;
      M.pcs.push(pc);
      pc.addEventListener('iceconnectionstatechange', function(){
        var s = pc.iceConnectionState;
        if (s === 'connected' || s === 'completed') stamp('ice');
      });
      return pc;
    }
  });

  setInterval(function(){
    if (!M.armed || M.m.firstSamples !== undefined) return;
    M.pcs.forEach(function(pc){
      if (pc.connectionState === 'closed') return;
      pc.getStats().then(function(report){
        var now = performance.now();
        report.forEach(function(r){
          if (r.type !== 'inbound-rtp' || r.kind !== 'audio') return;
          if ((r.packetsReceived || 0) > 0) stamp('firstPacket', now);
          if ((r.jitterBufferEmittedCount || 0) > 0) stamp('firstSamples', now);
        });
      }, function(){});
    });
  }, 20);

  M.read = function(){
    var out = {};
    var t0 = M.m.click;
    Object.keys(M.m).forEach(function(k){ out[k] = M.m[k]; });
    var res = performance.getEntriesByType('resource').filter(function(e){
      return e.name.indexOf('/voice/token') >= 0 && e.startTime >= M.mark;
    });
    var last = res[res.length - 1];
    if (last) { out.tokenStart = last.startTime; out.tokenEnd = last.responseEnd; }
    return out;
  };
})();
"""
