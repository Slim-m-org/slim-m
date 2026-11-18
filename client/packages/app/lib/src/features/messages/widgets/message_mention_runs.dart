// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A mention repeated over and over draws as one chip and a count.
library;

import 'message_inline_nodes.dart';

/// The shortest run of one mention that draws as a single chip.
const kMentionRunCollapse = 3;

/// [nodes] with each run of [kMentionRunCollapse] or more of the same user or
/// role mention, separated only by whitespace, drawn as its first mention and
/// a count. Notifications already reach each person once; a wall of chips
/// only pushes the conversation away.
List<InlineNode> collapseMentionRuns(List<InlineNode> nodes) {
  final out = <InlineNode>[];
  var i = 0;
  while (i < nodes.length) {
    final key = _mentionKey(nodes[i]);
    if (key == null) {
      out.add(nodes[i++]);
      continue;
    }
    var count = 1;
    var end = i + 1;
    var j = i + 1;
    while (j < nodes.length) {
      if (_isBlank(nodes[j])) {
        j++;
      } else if (_mentionKey(nodes[j]) == key) {
        count++;
        end = ++j;
      } else {
        break;
      }
    }
    if (count < kMentionRunCollapse) {
      out.add(nodes[i++]);
      continue;
    }
    out
      ..add(nodes[i])
      ..add(InlineText(' \u{00D7}$count'));
    i = end;
  }
  return out;
}

String? _mentionKey(InlineNode node) => switch (node) {
  InlineMention(:final raw) => 'u:${raw.toLowerCase()}',
  InlineRoleMention(:final name) => 'r:${name.toLowerCase()}',
  _ => null,
};

bool _isBlank(InlineNode node) =>
    node is InlineText && node.text.trim().isEmpty;
