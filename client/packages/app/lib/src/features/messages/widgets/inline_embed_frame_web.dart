// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real inline embed: an `<iframe>` pointed at the provider's player,
/// hosted through a registered platform view. Nothing here runs until
/// [buildInlineEmbedFrame] is first called for a given [src] - that only
/// happens on tap, from a link preview - so no request to the provider's
/// player happens merely from a preview rendering.
library;

import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// View types already registered this session, so a rebuild of the same
/// card does not try to register the same `viewType` twice - the engine
/// throws if it is asked to.
final Set<String> _registeredViewTypes = {};

/// [allow] is the iframe's permissions policy, the provider's own snippet.
/// It grants fullscreen too: the browser lets it override `allowfullscreen`.
Widget buildInlineEmbedFrame(Uri src, {required String allow}) {
  final viewType = 'slimm-embed-${Object.hash(src, allow)}';
  if (_registeredViewTypes.add(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final iframe = web.HTMLIFrameElement()
        ..src = src.toString()
        ..allow = allow;
      iframe.style
        ..setProperty('border', 'none')
        ..setProperty('width', '100%')
        ..setProperty('height', '100%');
      return iframe;
    });
  }
  return HtmlElementView(viewType: viewType);
}
