# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The in-page half of the share quality measurement.

Injected before the app boots. It stands in for a 4K monitor, because a
headless browser has no screen to capture, and reads sender and receiver
stats straight from the peer connections.

The fake screen is a canvas: text that scrolls in jumps plus a moving gradient patch, so the
encoder has both sharp edges and motion to work on. It honours the size and
frame rate the app asks getDisplayMedia for, capped at 3840x2160, the way a
real capture scales a bigger monitor down.
"""

SHIM = r"""
(function(){
  if (window.__shareProbe) return;
  var st = {pcs: [], asked: null, codec: window.__shareCodec || ''};
  window.__shareProbe = st;
  var Orig = window.RTCPeerConnection;
  window.RTCPeerConnection = new Proxy(Orig, {
    construct: function(target, args, newTarget){
      var pc = Reflect.construct(target, args, newTarget);
      st.pcs.push(pc);
      return pc;
    }
  });
  var addT = Orig.prototype.addTransceiver;
  Orig.prototype.addTransceiver = function(track){
    var t = addT.apply(this, arguments);
    try {
      if (st.codec && track && track.kind === 'video' && track.__fakeScreen) {
        var caps = RTCRtpSender.getCapabilities('video').codecs;
        var want = caps.filter(function(c){ return c.mimeType.toLowerCase() === 'video/' + st.codec; });
        var rest = caps.filter(function(c){ return want.indexOf(c) < 0; });
        t.setCodecPreferences(want.concat(rest));
      }
    } catch (e) { st.codecError = String(e); }
    return t;
  };
  function num(v){ return typeof v === 'number' ? v : (v && (v.ideal || v.max || v.exact)) || 0; }
  var SRC_W = window.__shareSourceW || 3840, SRC_H = window.__shareSourceH || 2160;
  navigator.mediaDevices.getDisplayMedia = function(c){
    var v = (c && c.video) || {};
    st.asked = JSON.stringify(c);
    var w = Math.min(SRC_W, num(v.width) || SRC_W);
    var h = Math.min(SRC_H, num(v.height) || Math.round(w * 9 / 16));
    var fps = num(v.frameRate) || 30;
    var cv = document.createElement('canvas');
    cv.width = w; cv.height = h;
    var g = cv.getContext('2d');
    var page = document.createElement('canvas');
    page.width = w; page.height = h * 2;
    var p = page.getContext('2d');
    p.fillStyle = '#fff'; p.fillRect(0, 0, w, h * 2);
    p.fillStyle = '#111';
    var line = Math.max(14, Math.round(h / 60));
    p.font = line + 'px monospace';
    for (var y = line, n = 0; y < h * 2; y += line * 1.4, n++) {
      p.fillText('const row' + n + ' = compute(' + (n * 7919 % 1000) + ', "slim-m screen share quality sample text");', line, y);
    }
    var patchW = Math.round(w / 6), patchH = Math.round(h / 6);
    var sprite = document.createElement('canvas');
    sprite.width = patchW; sprite.height = patchH;
    var sg = sprite.getContext('2d');
    var t0 = performance.now();
    function frame(){
      var t = performance.now() - t0;
      // The page jumps a few lines every 700 ms, like reading a document.
      var off = Math.round(Math.floor(t / 700) * line * 3) % h;
      g.drawImage(page, 0, off, w, h, 0, 0, w, h);
      // A smooth moving gradient stands in for a video playing in a window.
      var phase = (t / 1500) % 1;
      var grad = sg.createLinearGradient(0, 0, patchW, patchH);
      grad.addColorStop(0, 'hsl(' + Math.round(phase * 360) + ',70%,50%)');
      grad.addColorStop(1, 'hsl(' + Math.round(phase * 360 + 120) % 360 + ',70%,30%)');
      sg.fillStyle = grad; sg.fillRect(0, 0, patchW, patchH);
      sg.fillStyle = '#fff'; sg.beginPath();
      sg.arc(patchW * (0.2 + 0.6 * Math.abs(Math.sin(t / 900))), patchH / 2, patchH / 6, 0, 7); sg.fill();
      g.drawImage(sprite, Math.round(w / 2), Math.round(h / 3));
    }
    frame();
    var timer = setInterval(frame, 1000 / fps);
    var stream = cv.captureStream(fps);
    var track = stream.getVideoTracks()[0];
    track.__fakeScreen = true;
    track.addEventListener('ended', function(){ clearInterval(timer); });
    var stop = track.stop.bind(track);
    track.stop = function(){ clearInterval(timer); stop(); };
    return Promise.resolve(stream);
  };
  var KEYS = ['ssrc','rid','frameWidth','frameHeight','framesPerSecond','framesDecoded',
    'framesEncoded','framesDropped','framesReceived','bytesReceived','bytesSent','freezeCount',
    'totalFreezesDuration','qualityLimitationReason','qualityLimitationDurations','targetBitrate',
    'active','encoderImplementation','decoderImplementation','timestamp','pliCount','nackCount',
    'packetsLost','jitter','keyFramesEncoded','totalEncodeTime','qualityLimitationResolutionChanges'];
  window.__shareStats = async function(kind){
    var out = [];
    for (var i = 0; i < st.pcs.length; i++) {
      try {
        var r = await st.pcs[i].getStats(); var codecs = {};
        r.forEach(function(s){ if (s.type === 'codec') codecs[s.id] = s.mimeType; });
        r.forEach(function(s){
          if ((s.kind || s.mediaType) !== 'video') return;
          if (s.type !== (kind === 'in' ? 'inbound-rtp' : 'outbound-rtp')) return;
          var o = {codec: codecs[s.codecId]};
          KEYS.forEach(function(k){ if (s[k] !== undefined) o[k] = s[k]; });
          out.push(o);
        });
      } catch (e) {}
    }
    return JSON.stringify(out);
  };
  window.__shareParams = function(){
    var out = [];
    st.pcs.forEach(function(pc){
      pc.getSenders().forEach(function(snd){
        if (!snd.track || !snd.track.__fakeScreen) return;
        (snd.getParameters().encodings || []).forEach(function(e){
          out.push({rid: e.rid, maxBitrate: e.maxBitrate, scale: e.scaleResolutionDownBy, active: e.active});
        });
      });
    });
    return JSON.stringify(out);
  };
  window.__shareCap = async function(bps){
    var n = 0;
    for (var i = 0; i < st.pcs.length; i++) {
      var ss = st.pcs[i].getSenders();
      for (var j = 0; j < ss.length; j++) {
        if (!ss[j].track || !ss[j].track.__fakeScreen) continue;
        var pr = ss[j].getParameters();
        (pr.encodings || []).forEach(function(e){
          e.maxBitrate = Math.min(e.maxBitrate || bps, bps);
        });
        await ss[j].setParameters(pr); n++;
      }
    }
    return n;
  };
})();
"""
