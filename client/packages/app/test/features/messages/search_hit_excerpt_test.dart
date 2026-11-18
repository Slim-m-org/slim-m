// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A long search hit shows the few lines around its match and stays a list
/// row's height, rather than filling the results pane with the whole message.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_search.dart';
import 'package:slimm_app/src/features/channels/widgets/search_hit_excerpt.dart';

import 'message_row_harness.dart';

final _list = [for (var i = 1; i <= 60; i++) '${' ' * i}- item$i'].join('\n');

api.Message _hit(String content) => api.Message.fromJson({
  'id': 'm1',
  'channel_id': 'c1',
  'author_id': 'u1',
  'author_display_name': 'Ava',
  'seq': 1,
  'content': content,
  'created_at': 1,
});

void main() {
  test('a long message is cut to the lines around the match', () {
    final excerpt = searchHitExcerpt(_list, 'item59').split('\n');
    expect(excerpt.first, '…');
    expect(excerpt, contains(contains('- item59')));
    expect(
      excerpt.where((l) => l.contains('item')),
      hasLength(kSearchHitLines),
    );
  });

  test('a short message, or one with a code fence, is left whole', () {
    expect(searchHitExcerpt('a\nb\nc', 'b'), 'a\nb\nc');
    final fenced = '```\n${List.filled(20, 'x').join('\n')}\n```';
    expect(searchHitExcerpt(fenced, 'x'), fenced);
  });

  testWidgets('a sixty-line hit stays a few lines tall', (tester) async {
    await tester.pumpWidget(
      harness(
        ListView(
          children: [
            SearchResultRow(
              message: _hit(_list),
              query: 'item59',
              knownUsernames: const {},
              customEmoji: const {},
              onSelect: (_) {},
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('item59'), findsOneWidget);
    expect(find.textContaining('item30'), findsNothing);
    final row = find.byWidgetPredicate((w) => w is SearchResultRow);
    expect(tester.getSize(row).height, lessThan(300));
    expect(tester.takeException(), isNull);
  });
}
