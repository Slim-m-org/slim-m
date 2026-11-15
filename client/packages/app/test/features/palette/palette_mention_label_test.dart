// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message hit is read aloud with the member's name for a mention, the way
/// its chip shows it, while the text it matches on stays as stored.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/palette/widgets/command_palette_items.dart'
    show messageResultItem;

api.Message _hit(String content) => api.Message.fromJson({
  'id': 'm1',
  'channel_id': 'c1',
  'author_id': 'u1',
  'seq': 1,
  'content': content,
  'created_at': 1,
});

void main() {
  test('the label names the member a mention points at', () {
    final item = messageResultItem(
      _hit('ask @bob about it'),
      channelLabel: '#general',
      authorName: 'Priya',
      mentionNames: const {'bob': 'Robert'},
      onSelect: (_, _) async {},
    );

    expect(item.semanticLabel, 'Message from Priya: ask @Robert about it');
    expect(item.label, 'ask @bob about it');
  });

  test('without a resolved author the label still reads the name', () {
    final item = messageResultItem(
      _hit('ask @bob'),
      channelLabel: '#general',
      mentionNames: const {'bob': 'Robert'},
      onSelect: (_, _) async {},
    );

    expect(item.semanticLabel, 'ask @Robert');
  });
}
