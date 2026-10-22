# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The browser-side half of the driver.

Flutter web has no scripting surface of its own, so everything here reads or
drives its accessibility projection directly. Kept apart from the Python so
each is legible on its own, and so the client stays inside the line budget.
"""

# Every leaf widget on screen, plus the fields.
#
# A text field's accessible name lands on the <input> Flutter creates for it,
# not on the wrapping semantics node, so both are collected or every field on
# every screen looks unlabelled. A row that names itself (a channel, a member)
# keeps its label on the node wrapping its icon and text, so leaves alone miss
# it either.
NODES = """
(function(){
  var out=[];
  document.querySelectorAll('flt-semantics').forEach(function(e){
    var named=e.getAttribute('aria-label');
    if (!named && e.querySelector('flt-semantics')) return;
    var t=(named||e.textContent||'').trim();
    if(!t) return;
    var r=e.getBoundingClientRect();
    if(r.width<1||r.height<1) return;
    out.push({t:t,x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2),
              field:false});
  });
  document.querySelectorAll('input,textarea').forEach(function(e){
    var t=(e.getAttribute('aria-label')||e.getAttribute('placeholder')||'').trim();
    if(!t) return;
    var r=e.getBoundingClientRect();
    out.push({t:t,x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2),
              field:true});
  });
  return JSON.stringify(out);
})()"""


# A cheap fingerprint of the accessibility tree, to tell a screen that has
# stopped changing from one still redrawing, without reading every node.
SIGNATURE = """
(function(){
  var h=5381,n=0;
  document.querySelectorAll('flt-semantics').forEach(function(e){
    n++;
    var s=(e.getAttribute('aria-label')||'')+'|'+(e.textContent||'').length;
    for (var i=0;i<s.length;i++) h=((h<<5)+h+s.charCodeAt(i))|0;
  });
  return n+':'+h+':'+location.hash;
})()"""


def click(label_json):
    """Activate a widget the way a screen reader would.

    Flutter paints the same label onto a plain node and onto the tappable one
    beside it, and only the tappable one answers a click. The closest name wins
    rather than the last found: a channel row and its "Manage <name>" button
    both match the channel's own name, and taking the last opened the manage
    sheet every time.

    Neither candidate is always named by an `aria-label` attribute, though:
    a reply quote's own label renders as inline text rather than the
    attribute, so its derived name is that text glued to its rendered
    snippet - often longer than an enclosing row's own concise aria-label,
    which used to make "shorter wins" favour the row over the quote it
    contains. A tappable node nested inside another tappable match is always
    the more specific one, so containment is checked before length.
    """
    return """
    (function(){
      var want=%s;
      var hits=[];
      document.querySelectorAll('flt-semantics').forEach(function(e){
        var t=((e.getAttribute('aria-label')||'')+' '+
               (e.textContent||'')).toLowerCase();
        if (t.indexOf(want)>=0) hits.push(e);
      });
      var tappable=hits.filter(function(e){
        return e.hasAttribute('flt-tappable') ||
               e.getAttribute('role')==='button';
      });
      function name(e){
        return (e.getAttribute('aria-label')||e.textContent||'').trim();
      }
      tappable.sort(function(x,y){
        var nx=name(x), ny=name(y);
        if ((nx.toLowerCase()===want)!==(ny.toLowerCase()===want)) {
          return nx.toLowerCase()===want ? -1 : 1;
        }
        var sx=nx.toLowerCase().indexOf(want)===0;
        var sy=ny.toLowerCase().indexOf(want)===0;
        if (sx!==sy) return sx ? -1 : 1;
        if (x!==y && x.contains(y)) return 1;
        if (x!==y && y.contains(x)) return -1;
        return nx.length-ny.length;
      });
      var target=tappable[0];
      if (!target) {
        target=hits.filter(function(e){
          return !e.querySelector('flt-semantics');
        }).pop();
      }
      if (!target) return false;
      target.click();
      return true;
    })()""" % label_json


def focus_field(label_json):
    """Focus a field by its accessible name rather than by where it looks."""
    return """
    (function(){
      var els=document.querySelectorAll('input,textarea');
      for (var i=0;i<els.length;i++) {
        var t=(els[i].getAttribute('aria-label')||
               els[i].getAttribute('placeholder')||'');
        if (t.toLowerCase().indexOf(%s)>=0) { els[i].focus(); return true; }
      }
      return false;
    })()""" % label_json


# Catch the picker's <input> at the moment it is made.
#
# Flutter's web file picker builds the element, clicks it, and never puts it in
# the document, so there is nothing for CDP's own DOM.setFileInputFiles to find
# and nothing to query for afterwards.
WATCH_FILES = """
(function(){
  window.__e2eFiles = [];
  if (window.__e2eHooked) return;
  var make = document.createElement.bind(document);
  document.createElement = function(tag){
    var el = make(tag);
    if (String(tag).toLowerCase() === 'input') window.__e2eFiles.push(el);
    return el;
  };
  window.__e2eHooked = 1;
})()"""


def give_file(payload_json, name_json, mime_json):
    """Hand the caught input a real file, as a person's picker would.

    `files` will not take a plain list but will take a DataTransfer's, which is
    how a file arrives with no dialog for anyone to answer. Every input caught
    since the picker opened is answered, not just the last: more than one is
    sometimes made and only one of them is listened to.
    """
    return """
    (function(){
      var inputs=(window.__e2eFiles||[]).filter(function(e){
        return e.type === 'file';
      });
      if (!inputs.length) return 'no file input was created';
      var raw = atob(%s);
      var bytes = new Uint8Array(raw.length);
      for (var i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
      inputs.forEach(function(el){
        var file = new File([bytes], %s, {type: %s});
        var dt = new DataTransfer();
        dt.items.add(file);
        el.files = dt.files;
        el.dispatchEvent(new Event('change', {bubbles: true}));
        el.dispatchEvent(new Event('input', {bubbles: true}));
      });
      return 'ok';
    })()""" % (payload_json, name_json, mime_json)


def set_gestures(value_json):
    """Let real pointer events through to the canvas, or take them back.

    A tappable node sets `pointer-events: all` on itself, which beats the
    host's `none`, so the host alone leaves any button-like node (a canvas
    object's screen-reader node, say) catching the press. A stylesheet rule
    that outranks the inline value covers every node, including ones the
    engine adds later.
    """
    return ("(function(){var h=document.querySelector('flt-semantics-host');"
            "if(h) h.style.pointerEvents=%s;"
            "var s=document.getElementById('e2e-gestures');"
            "if(!s){s=document.createElement('style');s.id='e2e-gestures';"
            "document.head.appendChild(s);}"
            "s.textContent=(%s==='none')?"
            "'flt-semantics-host *,flt-platform-view,flt-platform-view *{pointer-events:none !important}':'';"
            "})()" % (value_json, value_json))


def canvas_rect():
    """The Voice Canvas surface's own bounding rect.

    Its one container Semantics node carries a label starting "Canvas,"
    (object counts, or "loading"); that same rect is the coordinate frame
    drawing and dragging happen in - see e2e_canvas.py's own doc for why
    the rect's top-left is all the geometry this harness ever needs. The
    label lands as inline text rather than an `aria-label` attribute, the
    same shape NODES already works around for a reply's quote button, so a
    node is only a candidate if it carries no nested flt-semantics of its
    own - or its *own* text, not an ancestor's, would answer first.
    """
    return """
    (function(){
      var els=document.querySelectorAll('flt-semantics');
      for (var i=0;i<els.length;i++){
        var e=els[i];
        var named=e.getAttribute('aria-label');
        if (!named && e.querySelector('flt-semantics')) continue;
        var t=(named||e.textContent||'').trim();
        if (t.indexOf('Canvas,')===0){
          var r=e.getBoundingClientRect();
          return JSON.stringify({x:r.x,y:r.y,width:r.width,height:r.height});
        }
      }
      return null;
    })()"""


def paste_image(payload_json, name_json, mime_json):
    """Dispatch a real browser `paste` event carrying an image file.

    The web build reads a pasted image off this DOM event directly, never
    the async clipboard-read API (see composer_clipboard_image_web.dart's
    own doc for why), so this is the same event a person's Ctrl+V produces -
    not a shortcut around it.
    """
    return """
    (function(){
      var raw = atob(%s);
      var bytes = new Uint8Array(raw.length);
      for (var i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
      var file = new File([bytes], %s, {type: %s});
      var dt = new DataTransfer();
      dt.items.add(file);
      var ev = new ClipboardEvent('paste', {
        clipboardData: dt, bubbles: true, cancelable: true});
      document.dispatchEvent(ev);
      return 'ok';
    })()""" % (payload_json, name_json, mime_json)
