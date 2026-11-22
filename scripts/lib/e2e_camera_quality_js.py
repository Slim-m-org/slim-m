# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The in-page half of the camera quality measurement.

Injected after sign-in and before the call, so every peer connection the call
creates is seen. It reads sender and receiver video stats straight from them;
the camera itself is Chrome's own fake video device, so nothing is stubbed.
"""

SHIM = r"""
(function(){
  if (window.__camProbe) return;
  var st = {pcs: [], orig: window.RTCPeerConnection};
  window.__camProbe = st;
  window.RTCPeerConnection = new Proxy(st.orig, {
    construct: function(target, args, newTarget){
      var pc = Reflect.construct(target, args, newTarget);
      st.pcs.push(pc);
      return pc;
    }
  });
  var KEYS = ['ssrc','rid','frameWidth','frameHeight','framesEncoded','framesDecoded',
    'framesPerSecond','freezeCount','totalFreezesDuration','active','timestamp',
    'qualityLimitationReason','bytesSent','bytesReceived'];
  window.__camStats = async function(kind){
    var out = [];
    for (var i = 0; i < st.pcs.length; i++) {
      try {
        var r = await st.pcs[i].getStats();
        r.forEach(function(s){
          if ((s.kind || s.mediaType) !== 'video') return;
          if (s.type !== (kind === 'in' ? 'inbound-rtp' : 'outbound-rtp')) return;
          var o = {};
          KEYS.forEach(function(k){ if (s[k] !== undefined) o[k] = s[k]; });
          out.push(o);
        });
      } catch (e) {}
    }
    return JSON.stringify(out);
  };
  window.__camParams = function(){
    var out = [];
    st.pcs.forEach(function(pc){
      pc.getSenders().forEach(function(snd){
        if (!snd.track || snd.track.kind !== 'video' || snd.track.readyState !== 'live') return;
        (snd.getParameters().encodings || []).forEach(function(e){
          out.push({rid: e.rid, maxBitrate: e.maxBitrate, maxFramerate: e.maxFramerate,
                    scale: e.scaleResolutionDownBy, active: e.active});
        });
      });
    });
    return JSON.stringify(out);
  };
  window.__camSettings = function(){
    var out = [];
    st.pcs.forEach(function(pc){
      pc.getSenders().forEach(function(snd){
        if (snd.track && snd.track.kind === 'video' && snd.track.readyState === 'live') {
          var g = snd.track.getSettings();
          out.push({width: g.width, height: g.height, frameRate: g.frameRate});
        }
      });
    });
    return JSON.stringify(out);
  };
})();
"""

UNINSTALL = ("(function(){var p=window.__camProbe;"
             "if(p){window.RTCPeerConnection=p.orig;delete window.__camProbe;}})()")
