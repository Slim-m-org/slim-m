// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Move to category..." on a channel's menu: a manager files a channel under
/// any category, or none, without dragging it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show ChannelOrderGroup;
import 'package:slimm_app/src/features/channels/widgets/channel_move.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_reorder.dart'
    show ChannelSection;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../../support/menu_gestures.dart';

Channel _channel(String id, {String? categoryId, String? lobby}) => Channel(
  id: id,
  name: id,
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  categoryId: categoryId,
  roomLobbyId: lobby,
);

const _dev = ChannelCategoryRow(id: 'dev', name: 'dev', position: 0);
const _fun = ChannelCategoryRow(id: 'fun', name: 'fun', position: 1);

Map<String?, List<String>> _byCategory(List<ChannelOrderGroup> groups) => {
  for (final g in groups) g.categoryId: g.channelIds,
};

void main() {
  group('groupsAfterMoveTo', () {
    final sections = <ChannelSection>[
      (null, [_channel('general')]),
      (_dev, [_channel('a', categoryId: 'dev')]),
      (_fun, const []),
    ];

    test('files the channel at the end of the chosen category', () {
      final groups = groupsAfterMoveTo(sections, 'general', 'dev')!;

      expect(_byCategory(groups), {
        null: <String>[],
        'dev': ['a', 'general'],
        'fun': <String>[],
      });
    });

    test('an empty category and "no category" are both reachable', () {
      expect(_byCategory(groupsAfterMoveTo(sections, 'a', null)!), {
        null: ['general', 'a'],
        'dev': <String>[],
        'fun': <String>[],
      });
      expect(groupsAfterMoveTo(sections, 'a', 'fun')!.last.channelIds, ['a']);
    });

    test('the channel already there, or a category not listed, is a no-op', () {
      expect(groupsAfterMoveTo(sections, 'a', 'dev'), isNull);
      expect(groupsAfterMoveTo(sections, 'a', 'gone'), isNull);
    });

    test('a lobby takes its rooms with it', () {
      final lobbies = <ChannelSection>[
        (
          null,
          [
            _channel('lobby'),
            _channel('room', lobby: 'lobby'),
            _channel('other'),
          ],
        ),
        (_dev, const []),
      ];

      final groups = groupsAfterMoveTo(lobbies, 'lobby', 'dev')!;

      expect(_byCategory(groups), {
        null: ['other'],
        'dev': ['lobby', 'room'],
      });
    });
  });

  testWidgets('the channel menu offers it and files the channel', (
    tester,
  ) async {
    List<ChannelOrderGroup>? sent;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ChannelCategorySections(
              channels: [_channel('general')],
              categories: const [_dev, _fun],
              selectedId: null,
              canManage: true,
              onReorder: (groups) => sent = groups,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await rightClickMenu(tester, find.text('general'));
    await tester.tap(find.text('Move to category...'));
    await pumpFrames(tester);
    await tester.tap(find.text('fun').last);
    await pumpFrames(tester);

    expect(_byCategory(sent!)['fun'], ['general']);
  });

  testWidgets('a member who cannot manage is offered no such entry', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ChannelCategorySections(
              channels: [_channel('general')],
              categories: const [_dev],
              selectedId: null,
              canManage: false,
              onReorder: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await rightClickMenu(tester, find.text('general'));

    expect(find.text('Move to category...'), findsNothing);
  });
}
