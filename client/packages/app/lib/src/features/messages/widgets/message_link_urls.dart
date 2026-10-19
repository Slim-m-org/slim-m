// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web addresses a message carries, for its "Copy link address" rows.
library;

import 'message_inline.dart';

/// Most rows a message menu grows by; a wall of links gains nothing past this.
const int maxLinkAddressRows = 5;

final RegExp _fence = RegExp(r'```[\s\S]*?```');

/// The distinct http and https addresses in [content], in reading order.
///
/// Fenced code is skipped, as the renderer does not make links of it either.
List<String> messageLinkUrls(String content) {
  final seen = <String>{};
  void walk(List<InlineNode> nodes) {
    for (final node in nodes) {
      switch (node) {
        case InlineLink(:final url):
          seen.add(url);
        case InlineBold(:final children) ||
            InlineItalic(:final children) ||
            InlineStrikethrough(:final children) ||
            InlineSpoiler(:final children):
          walk(children);
        default:
      }
    }
  }

  walk(parseInline(content.replaceAll(_fence, ' ')));
  return seen.take(maxLinkAddressRows).toList(growable: false);
}
