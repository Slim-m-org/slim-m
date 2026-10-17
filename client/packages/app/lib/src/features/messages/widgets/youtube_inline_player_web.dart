// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real inline embed: an `<iframe>` pointed at `youtube-nocookie.com`,
/// hosted through a registered platform view. Nothing here runs until
/// [buildYoutubeInlinePlayer] is first called for a given [embedUrl] - that
/// only happens on tap, from `link_preview_card.dart` - so no request to
/// Google's own player happens merely from a preview rendering.
library;

import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// View types already registered this session, so a rebuild of the same
/// card does not try to register the same `viewType` twice - the engine
/// throws if it is asked to.
final Set<String> _registeredViewTypes = {};

Widget buildYoutubeInlinePlayer(Uri embedUrl) {
  final viewType = 'slimm-youtube-embed-${embedUrl.hashCode}';
  if (_registeredViewTypes.add(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final iframe = web.HTMLIFrameElement()
        ..src = embedUrl.toString()
        ..allow = 'autoplay; encrypted-media; picture-in-picture'
        ..allowFullscreen = true;
      iframe.style
        ..setProperty('border', 'none')
        ..setProperty('width', '100%')
        ..setProperty('height', '100%');
      return iframe;
    });
  }
  return HtmlElementView(viewType: viewType);
}
