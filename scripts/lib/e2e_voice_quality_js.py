# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The in-page half of the voice quality harness.

Runs after e2e_audio_js.PROBE, whose `window.__e2eAudio.pcs` it polls. It taps
the decoded remote audio into PCM (what the listener's speakers would get,
before any app gain) and samples the receive-side concealment counters.
"""

# Capture without browser voice processing, so the call is judged alone; E2E_VQ_PROCESSING=1 keeps it.
RAW_CAPTURE_ALL = r"""
(function(){
  var md = navigator.mediaDevices;
  var orig = md.getUserMedia.bind(md);
  md.getUserMedia = function(constraints){
    if (constraints && constraints.audio) {
      var a = constraints.audio === true ? {} : Object.assign({}, constraints.audio);
      a.noiseSuppression = false; a.echoCancellation = false; a.autoGainControl = false;
      constraints = Object.assign({}, constraints, {audio: a});
    }
    return orig(constraints);
  };
})();
"""

# Merges window.__vqSdp into the opus fmtp of both descriptions; the answer's fmtp is what the encoder follows.
SDP_TWEAK = r"""
(function(){
  var proto = RTCPeerConnection.prototype;
  function wrap(name){
    var orig = proto[name];
    proto[name] = function(desc){ return orig.call(this, munge(desc)); };
  }
  function munge(desc){
    var tweak = window.__vqSdp;
    if (tweak && desc && desc.sdp) {
      var sdp = desc.sdp;
      var m = /a=rtpmap:(\d+) opus\/48000\/2/.exec(sdp);
      if (m) {
        var re = new RegExp('a=fmtp:' + m[1] + ' (.*)');
        sdp = sdp.replace(re, function(_, params){
          var map = {};
          params.split(';').forEach(function(p){
            var kv = p.split('='); map[kv[0]] = kv[1];
          });
          Object.keys(tweak).forEach(function(k){ map[k] = tweak[k]; });
          return 'a=fmtp:' + m[1] + ' ' + Object.keys(map).map(function(k){
            return map[k] === undefined ? k : k + '=' + map[k]; }).join(';');
        });
        desc = {type: desc.type, sdp: sdp};
      }
    }
    return desc;
  }
  wrap('setLocalDescription');
  wrap('setRemoteDescription');
})();
"""

COLLECT = r"""
(function(){
  var st = window.__e2eAudio;
  var vq = window.__vq = {stats: [], pair: null, codecs: {}, ready: false,
                          out: null, chunks: [], pcm: null, rate: 0, error: ''};
  var t0 = performance.now();
  var FIELDS = ['concealedSamples', 'concealmentEvents', 'silentConcealedSamples',
    'insertedSamplesForDeceleration', 'removedSamplesForAcceleration', 'jitter',
    'jitterBufferDelay', 'jitterBufferEmittedCount', 'jitterBufferTargetDelay',
    'packetsLost', 'packetsReceived', 'packetsDiscarded', 'totalSamplesReceived',
    'totalSamplesDuration', 'audioLevel', 'totalAudioEnergy', 'fecPacketsReceived',
    'fecPacketsDiscarded', 'bytesReceived'];
  function poll(){
    st.pcs.forEach(function(pc){
      if (pc.connectionState === 'closed') return;
      pc.getStats().then(function(report){
        var codecs = {}, pairs = [];
        report.forEach(function(r){
          if (r.type === 'codec') codecs[r.id] = r.mimeType + ' ' + (r.sdpFmtpLine || '');
          if (r.type === 'candidate-pair' && r.nominated && r.state === 'succeeded')
            pairs.push(r);
        });
        report.forEach(function(r){
          if (r.type === 'inbound-rtp' && r.kind === 'audio') {
            var row = {t: performance.now() - t0, ssrc: r.ssrc};
            FIELDS.forEach(function(f){ if (r[f] !== undefined) row[f] = r[f]; });
            vq.stats.push(row);
            vq.codecs[r.ssrc] = codecs[r.codecId] || '';
          }
        });
        report.forEach(function(r){
          if (r.type === 'outbound-rtp' && r.kind === 'audio') {
            vq.out = {codec: codecs[r.codecId] || '', packetsSent: r.packetsSent,
                      bytesSent: r.bytesSent, t: performance.now() - t0};
          }
        });
        pairs.forEach(function(p){
          var local = report.get(p.localCandidateId) || {};
          var remote = report.get(p.remoteCandidateId) || {};
          vq.pair = {protocol: local.protocol, local: local.candidateType,
                     remote: remote.candidateType, rtt: p.currentRoundTripTime};
        });
      }).catch(function(){});
    });
  }
  setInterval(poll, 500);
  vq.mark = function(){ return performance.now() - t0; };
  vq.start = async function(){
    try {
      var el = Array.prototype.find.call(document.querySelectorAll('audio'),
        function(e){ return e.srcObject && e.srcObject.getAudioTracks().length; });
      var ctx = new AudioContext({sampleRate: 48000});
      await ctx.resume();
      var code = 'class T extends AudioWorkletProcessor{process(i){var c=i[0][0];'
        + 'if(c)this.port.postMessage(c.slice(0));return true;}}'
        + 'registerProcessor("vq-tap",T);';
      var url = URL.createObjectURL(new Blob([code], {type: 'text/javascript'}));
      await ctx.audioWorklet.addModule(url);
      var node = new AudioWorkletNode(ctx, 'vq-tap', {numberOfOutputs: 0});
      node.port.onmessage = function(e){ vq.chunks.push(e.data); };
      ctx.createMediaStreamSource(el.srcObject).connect(node);
      vq.rate = ctx.sampleRate;
      vq.ctx = ctx;
      vq.node = node;
      vq.ready = true;
    } catch (e) { vq.error = String(e); }
  };
  vq.stop = function(){
    if (vq.node) vq.node.port.onmessage = null;
    if (vq.ctx) vq.ctx.close();
    var total = 0;
    vq.chunks.forEach(function(c){ total += c.length; });
    var pcm = new Int16Array(total), at = 0;
    vq.chunks.forEach(function(c){
      for (var i = 0; i < c.length; i++) {
        pcm[at++] = Math.max(-32768, Math.min(32767, Math.round(c[i] * 32768)));
      }
    });
    vq.chunks = [];
    vq.pcm = pcm;
    return total;
  };
  vq.slice = function(from, count){
    var bytes = new Uint8Array(vq.pcm.buffer, from * 2, count * 2), s = '';
    for (var i = 0; i < bytes.length; i += 8192) {
      s += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
    }
    return btoa(s);
  };
  vq.setSender = function(fields){
    st.pcs.forEach(function(pc){
      if (pc.connectionState === 'closed') return;
      pc.getSenders().forEach(function(sender){
        if (!sender.track || sender.track.kind !== 'audio') return;
        var p = sender.getParameters();
        if (!p.encodings || !p.encodings.length) return;
        Object.keys(fields).forEach(function(k){ p.encodings[0][k] = fields[k]; });
        sender.setParameters(p);
      });
    });
  };
  vq.reset = function(){ vq.chunks = []; vq.pcm = null; vq.stats = []; };
})();
"""
