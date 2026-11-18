// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A mention repeated hundreds of times draws as one chip and a count, while
/// a mention said twice, or mentions of different people, draw as typed.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_inline.dart';
import 'package:slimm_app/src/features/messages/widgets/message_mention_runs.dart';

List<InlineNode> _collapsed(String text) =>
    collapseMentionRuns(parseInline(text));

void main() {
  test('three hundred of one mention are one mention and a count', () {
    final nodes = _collapsed('hey ${List.filled(300, '@ava').join(' ')} ok');
    expect(nodes.whereType<InlineMention>(), hasLength(1));
    final texts = nodes.whereType<InlineText>().map((n) => n.text).join();
    expect(texts, contains('\u{00D7}300'));
    expect(texts, endsWith(' ok'));
  });

  test('a repeated role mention collapses the same way', () {
    final nodes = _collapsed(List.filled(5, '@[Core Team]').join(' '));
    expect(nodes.whereType<InlineRoleMention>(), hasLength(1));
  });

  test('a mention said twice, or different people, are left as typed', () {
    expect(_collapsed('@ava @ava').whereType<InlineMention>(), hasLength(2));
    expect(
      _collapsed('@ava @ben @ava @ben').whereType<InlineMention>(),
      hasLength(4),
    );
    expect(
      _collapsed('@ava, @ava, @ava').whereType<InlineMention>(),
      hasLength(3),
    );
  });
}
