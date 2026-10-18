# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The in-page half of the audio and video probe.

Injected before the app boots (Page.addScriptToEvaluateOnNewDocument), so it
sees every AudioContext and RTCPeerConnection the app makes. It measures what
a listener would hear, not what a widget says: for each remote audio element
it reports the level after the app's own gain graph, or after the element's
mute and volume when there is no graph (the app splices one in only for a
volume other than 100%, see rtc/lib/src/gain_graph_registry.dart).

A window where the element is not actually playing, or where the app's own
AudioContext is suspended under a tap, is flagged and reads as silence; the
Python side refuses to judge a measurement made of such windows.
"""

PROBE = r"""
(function(){
  if (window.__e2eAudio) return;
  var AC = window.AudioContext || window.webkitAudioContext;
  var st = {t0: performance.now(), taps: [], sources: new Map(),
            pcs: [], series: {}, streams: new Map(), video: {}};
  window.__e2eAudio = st;
  var origSrc = AC.prototype.createMediaStreamSource;
  var origConnect = AudioNode.prototype.connect;
  var origDisconnect = AudioNode.prototype.disconnect;
  AC.prototype.createMediaStreamSource = function(stream){
    var node = origSrc.call(this, stream);
    st.sources.set(node, stream);
    return node;
  };
  AudioNode.prototype.connect = function(dest){
    var ret = origConnect.apply(this, arguments);
    try {
      if (this instanceof MediaStreamAudioSourceNode && dest instanceof GainNode) {
        dest.__e2eStream = st.sources.get(this);
      } else if (this instanceof GainNode && dest instanceof AudioDestinationNode) {
        var an = this.context.createAnalyser();
        an.fftSize = 2048;
        origConnect.call(this, an);
        var tap = {gain: this, analyser: an, dead: false};
        this.__e2eTap = tap;
        st.taps.push(tap);
      }
    } catch (e) {}
    return ret;
  };
  AudioNode.prototype.disconnect = function(){
    if (this.__e2eTap && arguments.length === 0) this.__e2eTap.dead = true;
    return origDisconnect.apply(this, arguments);
  };
  var OrigPC = window.RTCPeerConnection;
  window.RTCPeerConnection = new Proxy(OrigPC, {
    construct: function(target, args, newTarget){
      var pc = Reflect.construct(target, args, newTarget);
      st.pcs.push(pc);
      return pc;
    }
  });
  var gum = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
  st.gum = [];
  navigator.mediaDevices.getUserMedia = function(c){
    st.gum.push(JSON.stringify(c));
    return gum(c);
  };
  var own = new AC();
  function level(an){
    var buf = new Float32Array(an.fftSize);
    an.getFloatTimeDomainData(buf);
    var s = 0;
    for (var i = 0; i < buf.length; i++) s += buf[i] * buf[i];
    return Math.sqrt(s / buf.length);
  }
  function preGain(stream){
    var rec = st.streams.get(stream.id);
    if (rec && rec.stream === stream) return rec.an;
    var an = own.createAnalyser();
    an.fftSize = 2048;
    origConnect.call(origSrc.call(own, stream), an);
    st.streams.set(stream.id, {stream: stream, an: an});
    return an;
  }
  function tapFor(stream){
    for (var i = st.taps.length - 1; i >= 0; i--) {
      var t = st.taps[i];
      if (!t.dead && t.gain.__e2eStream === stream) return t;
    }
    return null;
  }
  function sample(){
    var now = performance.now() - st.t0;
    document.querySelectorAll('audio').forEach(function(el){
      var stream = el.srcObject;
      if (!stream || !stream.id) return;
      var pre = level(preGain(stream));
      var tap = tapFor(stream);
      var playing = !el.paused && !el.ended && el.readyState >= 2;
      var flag = '';
      if (!playing) flag = 'stalled';
      else if (tap && tap.gain.context.state === 'suspended') flag = 'suspended';
      var eff = tap ? level(tap.analyser)
                    : (!playing || el.muted ? 0 : pre * el.volume);
      if (flag) eff = 0;
      var list = st.series[stream.id] || (st.series[stream.id] = []);
      list.push([now, eff, pre, flag]);
      if (list.length > 4000) list.splice(0, list.length - 4000);
      st.series[stream.id].elementId = el.id;
    });
  }
  setInterval(function(){ try { own.resume(); sample(); } catch (e) {} }, 50);
  st.now = function(){ return performance.now() - st.t0; };
  st.since = function(id, from){
    return (st.series[id] || []).filter(function(r){ return r[0] >= from; });
  };
  st.listen = function(){
    var out = [];
    document.querySelectorAll('audio').forEach(function(el){
      if (el.srcObject && el.srcObject.id) {
        out.push({stream: el.srcObject.id, element: el.id, muted: el.muted,
                  volume: el.volume, graph: !!tapFor(el.srcObject)});
      }
    });
    return out;
  };
  st.inb = {bytes: 0, packets: 0};
  setInterval(function(){
    var total = {bytes: 0, packets: 0}, left = st.pcs.length;
    st.pcs.forEach(function(pc){
      if (pc.connectionState === 'closed') { left--; return; }
      pc.getStats().then(function(report){
        report.forEach(function(r){
          if (r.type === 'inbound-rtp' && r.kind === 'audio') {
            total.bytes += r.bytesReceived || 0;
            total.packets += r.packetsReceived || 0;
          }
        });
        if (--left <= 0) st.inb = total;
      }, function(){ left--; });
    });
  }, 40);
  st.senders = function(){
    var out = [];
    st.pcs.forEach(function(pc){
      if (pc.connectionState === 'closed') return;
      pc.getSenders().forEach(function(s){
        var t = s.track;
        if (!t) return;
        out.push({kind: t.kind, id: t.id, label: t.label, state: t.readyState,
                  enabled: t.enabled, settings: t.getSettings()});
      });
    });
    return out;
  };
  function msidOf(trackId){
    for (var i = 0; i < st.pcs.length; i++) {
      var d = st.pcs[i].remoteDescription;
      if (!d) continue;
      var m = new RegExp('a=msid:(\\S+) ' + trackId).exec(d.sdp);
      if (m) return m[1];
    }
    return '';
  }
  st.inbound = {};
  function pollInbound(){
    st.pcs.forEach(function(pc){
      if (pc.connectionState === 'closed') return;
      pc.getStats().then(function(report){
        report.forEach(function(r){
          if (r.type === 'inbound-rtp' && r.kind === 'video') {
            st.inbound[r.id] = {frames: r.framesDecoded || 0,
                                bytes: r.bytesReceived || 0,
                                width: r.frameWidth || 0};
          }
        });
      }).catch(function(){});
    });
  }
  setInterval(pollInbound, 500);
  st.inboundVideo = function(){ return st.inbound; };
  st.videos = function(){
    var out = [];
    document.querySelectorAll('video').forEach(function(v, index){
      var w = v.videoWidth, h = v.videoHeight;
      var q = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : {};
      var rec = {index: index, width: w, height: h,
                 frames: q.totalVideoFrames || 0, mean: 0, spread: 0,
                 stream: (v.srcObject && v.srcObject.id) || '', sfu: '',
                 display: false};
      var vt = v.srcObject && v.srcObject.getVideoTracks
        ? v.srcObject.getVideoTracks()[0] : null;
      if (vt) rec.sfu = msidOf(vt.id);
      if (vt) rec.display = !!(vt.getSettings && vt.getSettings().displaySurface);
      var box = v.getBoundingClientRect();
      rec.boxW = Math.round(box.width); rec.boxH = Math.round(box.height);
      if (w > 0 && h > 0) {
        try {
          var c = document.createElement('canvas');
          c.width = 32; c.height = 18;
          var g = c.getContext('2d');
          g.drawImage(v, 0, 0, 32, 18);
          var d = g.getImageData(0, 0, 32, 18).data, vals = [];
          for (var i = 0; i < d.length; i += 4) {
            vals.push(0.2126 * d[i] + 0.7152 * d[i+1] + 0.0722 * d[i+2]);
          }
          var m = vals.reduce(function(a, b){ return a + b; }, 0) / vals.length;
          var sd = Math.sqrt(vals.reduce(function(a, b){
            return a + (b - m) * (b - m); }, 0) / vals.length);
          rec.mean = m; rec.spread = sd;
        } catch (e) { rec.error = String(e); }
      }
      out.push(rec);
    });
    return out;
  };
})();
"""

# The noise scenario's control arm: only the browser's noise suppression refused.
RAW_CAPTURE = r"""
(function(){
  var md = navigator.mediaDevices;
  var orig = md.getUserMedia.bind(md);
  md.getUserMedia = function(constraints){
    if (constraints && constraints.audio) {
      var a = constraints.audio === true ? {} : Object.assign({}, constraints.audio);
      a.noiseSuppression = false;
      constraints = Object.assign({}, constraints, {audio: a});
    }
    return orig(constraints);
  };
})();
"""

# A headless share has no system audio, so the share is given a tone as its audio.
SHARE_TONE = r"""
(function(){
  var md = navigator.mediaDevices;
  var orig = md.getDisplayMedia.bind(md);
  md.getDisplayMedia = async function(constraints){
    var video = Object.assign({}, constraints || {}, {audio: false});
    var stream = await orig(video);
    var Ctx = window.AudioContext || window.webkitAudioContext;
    var ctx = new Ctx();
    await ctx.resume();
    var osc = ctx.createOscillator();
    osc.frequency.value = 523;
    var gain = ctx.createGain();
    gain.gain.value = 0.3;
    var dest = ctx.createMediaStreamDestination();
    osc.connect(gain);
    gain.connect(dest);
    osc.start();
    dest.stream.getAudioTracks().forEach(function(t){ stream.addTrack(t); });
    return stream;
  };
})();
"""
