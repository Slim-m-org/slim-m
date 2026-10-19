# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The in-page half of the latency and experience-timing scenarios.

Runs after e2e_audio_js.PROBE. Everything is stamped with one epoch clock
(`performance.timeOrigin + performance.now()`), which both headless browsers
share because they run on one machine, so a send time in one page and a
receive time in the other subtract directly.
"""

# Keeps the microphone stream the app opened, so a local tap can listen to what is being sent.
STASH = r"""
(function(){
  var xp = window.__xp = window.__xp || {events: [], local: null, series: [], seen: {}};
  xp.now = function(){ return performance.timeOrigin + performance.now(); };
  xp.log = function(name, extra){
    xp.events.push(Object.assign({n: name, t: xp.now()}, extra || {}));
  };
  var md = navigator.mediaDevices;
  var orig = md.getUserMedia.bind(md);
  md.getUserMedia = function(c){
    return orig(c).then(function(s){
      if (s.getAudioTracks().length) xp.local = s;
      return s;
    });
  };
})();
"""

# Peer connection state changes, first remote packets and audio, sampled every 100 ms.
EVENTS = r"""
(function(){
  var xp = window.__xp, st = window.__e2eAudio, watched = new Set();
  function watch(pc, i){
    xp.log('pc-new', {pc: i});
    ['iceconnectionstatechange', 'connectionstatechange'].forEach(function(ev){
      pc.addEventListener(ev, function(){
        xp.log(ev === 'iceconnectionstatechange' ? 'ice' : 'conn',
               {pc: i, v: ev === 'iceconnectionstatechange'
                 ? pc.iceConnectionState : pc.connectionState});
      });
    });
  }
  setInterval(function(){
    st.pcs.forEach(function(pc, i){
      if (!watched.has(pc)) { watched.add(pc); watch(pc, i); }
      if (pc.connectionState === 'closed') return;
      pc.getStats().then(function(report){
        report.forEach(function(r){
          if (r.type !== 'inbound-rtp' || r.kind !== 'audio') return;
          var key = i + ':' + r.ssrc;
          if (r.packetsReceived > 0 && !xp.seen['p' + key]) {
            xp.seen['p' + key] = 1; xp.log('first-packet', {pc: i});
          }
          if (r.totalAudioEnergy > 0.0005 && !xp.seen['e' + key]) {
            xp.seen['e' + key] = 1; xp.log('first-energy', {pc: i});
          }
          xp.series.push({t: xp.now(), pc: i, packets: r.packetsReceived,
                          samples: r.totalSamplesReceived,
                          concealed: r.concealedSamples,
                          energy: r.totalAudioEnergy});
        });
      }).catch(function(){});
    });
  }, 100);
})();
"""

# Logs when a semantics label containing each text appears or goes away.
LABELS = r"""
(function(){
  var xp = window.__xp, lit = {};
  xp.watchLabels = function(texts){
    function check(){
      var all = [];
      document.querySelectorAll('flt-semantics').forEach(function(e){
        var named = e.getAttribute('aria-label');
        if (!named && e.querySelector('flt-semantics')) return;
        all.push((named || e.textContent || '').toLowerCase());
      });
      texts.forEach(function(text){
        var on = all.some(function(l){ return l.indexOf(text.toLowerCase()) >= 0; });
        if (on !== !!lit[text]) { lit[text] = on; xp.log('label', {text: text, on: on}); }
      });
    }
    new MutationObserver(check).observe(document.documentElement, {
      subtree: true, childList: true, attributes: true,
      attributeFilter: ['aria-label'], characterData: true});
    check();
  };
})();
"""

# A timestamped PCM tap on any MediaStream: `await __xp.tap(stream)` then `.stop()`.
TAP = r"""
(function(){
  var xp = window.__xp;
  xp.taps = {};
  xp.tap = async function(name, stream){
    var tap = {chunks: [], offsets: [], first: null, frames: 0, off: Infinity, rate: 48000,
               error: '', ready: false};
    xp.taps[name] = tap;
    try {
    var ctx = new AudioContext({sampleRate: 48000});
    await ctx.resume();
    var code = 'class T extends AudioWorkletProcessor{process(i){var c=i[0][0];'
      + 'if(c)this.port.postMessage({d:c.slice(0),f:currentFrame});return true;}}'
      + 'registerProcessor("xp-tap",T);';
    var url = URL.createObjectURL(new Blob([code], {type: 'text/javascript'}));
    await ctx.audioWorklet.addModule(url);
    var node = new AudioWorkletNode(ctx, 'xp-tap', {numberOfOutputs: 0});
    node.port.onmessage = function(e){
      var arrived = performance.now();
      var m = e.data;
      if (tap.first === null) tap.first = m.f;
      // The smallest arrival-minus-render gap is the one with no queueing in it.
      tap.off = Math.min(tap.off, arrived - m.f / tap.rate * 1000);
      tap.chunks.push(m.d);
      tap.offsets.push(m.f);
      tap.frames += m.d.length;
      tap.last = m.f + m.d.length;
    };
    ctx.createMediaStreamSource(stream).connect(node);
    tap.ctx = ctx;
    tap.node = node;
    tap.ready = true;
    } catch (e) { tap.error = String(e); }
  };
  xp.tapRemote = function(name){
    var el = Array.prototype.find.call(document.querySelectorAll('audio'),
      function(e){ return e.srcObject && e.srcObject.getAudioTracks().some(
        function(t){ return t.readyState === 'live'; }); });
    return xp.tap(name, el.srcObject);
  };
  xp.tapLocal = function(name){ return xp.tap(name, xp.local); };
  xp.finish = function(name){
    var tap = xp.taps[name];
    tap.node.port.onmessage = null;
    tap.ctx.close();
    var total = tap.last - tap.first, filled = tap.frames;
    var pcm = new Int16Array(total);
    // Blocks the page never received stay zero, so an index is still a time.
    tap.chunks.forEach(function(c, k){
      var at = tap.offsets[k] - tap.first;
      for (var i = 0; i < c.length; i++) {
        pcm[at + i] = Math.max(-32768, Math.min(32767, Math.round(c[i] * 32768)));
      }
    });
    tap.chunks = [];
    tap.pcm = pcm;
    return {frames: total, missing: total - filled, first: tap.first, last: tap.last,
            startEpoch: performance.timeOrigin + tap.off + tap.first / tap.rate * 1000};
  };
  xp.slice = function(name, from, count){
    var bytes = new Uint8Array(xp.taps[name].pcm.buffer, from * 2, count * 2), s = '';
    for (var i = 0; i < bytes.length; i += 8192) {
      s += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
    }
    return btoa(s);
  };
})();
"""

ALL = STASH + EVENTS + LABELS + TAP
