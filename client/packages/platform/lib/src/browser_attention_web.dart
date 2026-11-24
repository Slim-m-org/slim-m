// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:js_interop';

import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:web/web.dart' as web;

import 'browser_attention.dart';

BrowserAttention createBrowserAttention() => _BrowserTab();

class _BrowserTab implements BrowserAttention {
  String? _baseTitle;
  String? _plainIcon;
  String? _writtenTitle;
  int _unread = 0;
  int _iconDraw = 0;
  web.MutationObserver? _titleWatch;

  @override
  void setUnread(int unread) {
    _unread = unread;
    _baseTitle ??= web.document.title;
    _watchTitle();
    _writeTitle();
    try {
      _drawIcon(unread > 0);
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'Could not badge the tab icon',
        error,
        stack,
      );
    }
  }

  void _writeTitle() {
    final title = tabTitleFor(_baseTitle ?? '', _unread);
    _writtenTitle = title;
    web.document.title = title;
  }

  /// The app re-sets the title on every rebuild; whatever it sets becomes the base the count is put in front of.
  void _watchTitle() {
    if (_titleWatch != null) return;
    final watch = web.MutationObserver(
      ((JSArray<web.MutationRecord> records, web.MutationObserver observer) {
        final current = web.document.title;
        if (current == _writtenTitle) return;
        _baseTitle = current;
        _writeTitle();
      }).toJS,
    );
    final head = web.document.head;
    if (head == null) return;
    watch.observe(
      head,
      web.MutationObserverInit(
        childList: true,
        characterData: true,
        subtree: true,
      ),
    );
    _titleWatch = watch;
  }

  void _drawIcon(bool badged) {
    final draw = ++_iconDraw;
    final link = web.document.querySelector('link[rel~="icon"]');
    if (link == null) return;
    final href = (link as web.HTMLLinkElement).href;
    final plain = _plainIcon ??= href;
    if (!badged) {
      link.href = plain;
      return;
    }
    final image = web.HTMLImageElement()..crossOrigin = 'anonymous';
    image.onload = ((web.Event _) {
      if (draw != _iconDraw) return;
      final canvas = web.HTMLCanvasElement()
        ..width = 32
        ..height = 32;
      final context = canvas.getContext('2d') as web.CanvasRenderingContext2D;
      context.drawImage(image, 0, 0, 32, 32);
      context.fillStyle = '#e5484d'.toJS;
      context.beginPath();
      context.arc(23, 9, 8, 0, 6.283185307179586);
      context.fill();
      link.href = canvas.toDataURL('image/png');
    }).toJS;
    image.src = plain;
  }

  @override
  void notify(
    String title,
    String body, {
    required String tag,
    void Function()? onClick,
  }) {
    if (!web.document.hidden) return;
    if (web.Notification.permission != 'granted') return;
    final shown = web.Notification(
      title,
      web.NotificationOptions(body: body, tag: tag),
    );
    shown.onclick = ((web.Event _) {
      web.window.focus();
      shown.close();
      onClick?.call();
    }).toJS;
  }
}
