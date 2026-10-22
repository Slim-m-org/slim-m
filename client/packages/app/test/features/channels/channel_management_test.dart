// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel rail sections and `canManage` gating: which section headers show,
/// and that a member without MANAGE_CHANNELS gets a read-only list. The
/// Channel settings screen's own round trip lives in
/// `channel_settings_management_test.dart`; the fixture both share is
/// `channel_management_harness.dart`.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' show ChannelOrderGroup;
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart'
    show channelIdInPath;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_insertion_line.dart';

import 'channel_management_harness.dart';

void main() {
  group('section header (backlog item 55)', () {
    testWidgets('the uncategorised section reads Channels, the same treatment '
        'DirectMessagesSection gives its own header - it used to be a blank '
        'label with a floating "+" and no explanation', (tester) async {
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'general')],
            categories: const [],
            selectedId: null,
            onReorder: (_) {},
          ),
          handler: (_) => http.Response('{}', 200),
        ),
      );

      expect(find.text('Channels'), findsOneWidget);
      expect(find.bySemanticsLabel('Channels'), findsOneWidget);
    });

    testWidgets('a named category keeps showing its own name above it', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'general', categoryId: 'cat-1')],
            categories: const [
              ChannelCategoryRow(id: 'cat-1', name: 'Text', position: 0),
            ],
            selectedId: null,
            onReorder: (_) {},
          ),
          handler: (_) => http.Response('{}', 200),
        ),
      );

      expect(find.text('Text'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Text')).dy,
        lessThan(tester.getTopLeft(find.text('general')).dy),
      );
    });

    testWidgets('an empty category is hidden from a member: migration 0031 '
        'seeds Text and Voice unconditionally, so every fresh deployment '
        'rendered two dead headers under the populated one', (tester) async {
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'general')],
            categories: const [
              ChannelCategoryRow(id: 'cat-1', name: 'Text', position: 0),
              ChannelCategoryRow(id: 'cat-2', name: 'Voice', position: 1),
            ],
            selectedId: null,
            onReorder: (_) {},
          ),
          handler: (_) => http.Response('{}', 200),
        ),
      );

      expect(find.text('Channels'), findsOneWidget);
      expect(find.text('Text'), findsNothing);
      expect(find.text('Voice'), findsNothing);
    });

    /// The owner: "the default category doesn't need to exist, either allow
    /// it to be deleted or remove it entirely". It cannot be deleted - it is
    /// the id-less bucket every uncategorised channel falls into, not a row
    /// in any table - so it earns its header only while it holds something.
    testWidgets('the implicit section is gone once every channel is filed, '
        'for a manager too', (tester) async {
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'general', categoryId: 'cat-1')],
            categories: const [
              ChannelCategoryRow(id: 'cat-1', name: 'Text', position: 0),
            ],
            selectedId: null,
            canManage: true,
            onReorder: (_) {},
          ),
          handler: (_) => http.Response('{}', 200),
        ),
      );

      expect(find.text('Channels'), findsNothing);
      expect(find.text('Text'), findsOneWidget);
    });

    /// A name is the user's. They typed "dev" in the categories screen, it
    /// read back "dev" there, and the rail shouted "DEV" - the owner called
    /// out the mismatch. The uppercase treatment stays on this app's own
    /// wording, where it is a style rather than an edit of someone's data.
    testWidgets('a category keeps the case it was typed in, while the app\'s '
        'own labels keep the uppercase treatment', (tester) async {
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [
              channel('c1', 'general'),
              channel('c2', 'chat', categoryId: 'cat-1'),
            ],
            categories: const [
              ChannelCategoryRow(id: 'cat-1', name: 'dev', position: 0),
            ],
            selectedId: null,
            onReorder: (_) {},
          ),
          handler: (_) => http.Response('{}', 200),
        ),
      );

      expect(find.text('dev'), findsOneWidget);
      expect(find.text('DEV'), findsNothing);
      expect(find.text('Channels'), findsOneWidget);
    });

    /// The owner: the channels "look like they are floating and the
    /// categories are line splits". They shared a left edge with their own
    /// header, so nothing said which rows belonged to which heading. Every
    /// channel hangs off its header now, the implicit section included, so
    /// the rail has one channel indent rather than one per section kind.
    testWidgets('a channel hangs off its header rather than sharing its left '
        'edge', (tester) async {
      // Left-aligned and bounded: the harness centres what it is given, and
      // a header is only as wide as its own word, so an unconstrained
      // comparison measures the centring rather than the indent.
      await tester.pumpWidget(
        harness(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 280,
              child: ChannelCategorySections(
                channels: [
                  channel('c1', 'loose'),
                  channel('c2', 'filed', categoryId: 'cat-1'),
                ],
                categories: const [
                  ChannelCategoryRow(id: 'cat-1', name: 'dev', position: 0),
                ],
                selectedId: null,
                onReorder: (_) {},
              ),
            ),
          ),
          handler: (_) => http.Response('{}', 200),
        ),
      );

      final headerLeft = tester.getTopLeft(find.text('dev')).dx;
      final filedLeft = tester.getTopLeft(find.text('filed')).dx;
      final looseLeft = tester.getTopLeft(find.text('loose')).dx;

      expect(filedLeft, greaterThan(headerLeft));
      expect(
        looseLeft,
        filedLeft,
        reason: 'one indent for every channel, whatever section it is in',
      );
    });

    /// Found while measuring the indent above. A Column centres by default
    /// and a header is only as wide as its own word, so without the add
    /// glyph beside it to stretch the row, every heading sat centred in the
    /// rail. Only a manager sees that glyph, so only a manager ever saw the
    /// headings line up with anything.
    testWidgets('a heading starts at the left edge for a member too, not '
        'centred in the rail', (tester) async {
      await tester.pumpWidget(
        harness(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 280,
              child: ChannelCategorySections(
                channels: [channel('c1', 'chat', categoryId: 'cat-1')],
                categories: const [
                  ChannelCategoryRow(id: 'cat-1', name: 'dev', position: 0),
                ],
                selectedId: null,
                onReorder: (_) {},
              ),
            ),
          ),
          handler: (_) => http.Response('{}', 200),
        ),
      );

      expect(
        tester.getTopLeft(find.text('dev')).dx,
        lessThan(40),
        reason: 'a centred heading is what made the rail read as adrift',
      );
    });

    /// The row menu's own "Remove from category" entry is gone (owner:
    /// dragging out is self-explanatory), so this is the only route left,
    /// and it has to work in exactly the state that used to defeat it: every
    /// channel filed, nothing uncategorised, the implicit "Channels" section
    /// nowhere on screen, and a pointer carry reaches it by dropping above the
    /// first category header, so nothing shifts under the pointer.
    testWidgets('a manager can carry a channel out of its category into the '
        'undrawn implicit section above the first header', (tester) async {
      List<ChannelOrderGroup>? reported;
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [
              channel('c1', 'chat', categoryId: 'cat-1'),
              channel('c2', 'notes', categoryId: 'cat-1'),
            ],
            categories: const [
              ChannelCategoryRow(id: 'cat-1', name: 'dev', position: 0),
            ],
            selectedId: null,
            canManage: true,
            onReorder: (groups) => reported = groups,
          ),
          handler: (_) => http.Response('{}', 200),
        ),
      );

      expect(find.text('Channels'), findsNothing);
      final header = tester.getRect(find.text('dev'));

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('chat')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.moveTo(Offset(header.center.dx, header.top - 4));
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('Channels'), findsNothing, reason: 'nothing shifts');
      expect(find.byType(RailInsertionLine), findsOneWidget);

      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(reported, isNotNull);
      expect(reported!.firstWhere((g) => g.categoryId == null).channelIds, [
        'c1',
      ]);
      expect(reported!.firstWhere((g) => g.categoryId == 'cat-1').channelIds, [
        'c2',
      ], reason: 'only the one channel moves; the rest of the category stays');
    });

    testWidgets('the row menu never offers to remove a channel from its '
        'category - dragging is the only route now', (tester) async {
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'chat', categoryId: 'cat-1')],
            categories: const [
              ChannelCategoryRow(id: 'cat-1', name: 'dev', position: 0),
            ],
            selectedId: null,
            canManage: true,
            onReorder: (_) {},
          ),
          handler: (_) => http.Response('{}', 200),
        ),
      );

      await tester.tap(find.bySemanticsLabel('Manage chat'));
      await tester.pumpAndSettle();

      expect(find.text('Remove from category'), findsNothing);
    });

    testWidgets('a manager keeps the header of an empty category', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'general')],
            categories: const [
              ChannelCategoryRow(id: 'cat-1', name: 'Text', position: 0),
            ],
            selectedId: null,
            canManage: true,
            onReorder: (_) {},
          ),
          handler: (_) => http.Response('{}', 200),
        ),
      );

      expect(find.text('Text'), findsOneWidget);
    });
  });

  group('gating on canManage', () {
    testWidgets('a member without MANAGE_CHANNELS sees a read-only list', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'general')],
            categories: const [],
            selectedId: null,
            onReorder: (_) {},
          ),
          handler: (_) => http.Response('{}', 200),
        ),
      );

      expect(find.bySemanticsLabel('Manage general'), findsNothing);
    });

    testWidgets('a manager sees a per-row manage button', (tester) async {
      await tester.pumpWidget(
        harness(
          ChannelCategorySections(
            channels: [channel('c1', 'general')],
            categories: const [],
            selectedId: null,
            canManage: true,
            onReorder: (_) {},
          ),
          handler: (_) => http.Response('{}', 200),
        ),
      );

      expect(find.bySemanticsLabel('Manage general'), findsOneWidget);
    });
  });

  group('channelIdInPath', () {
    test('reads the id only from a channel route', () {
      expect(channelIdInPath('/channels/c1'), 'c1');
      expect(channelIdInPath('/channels'), isNull);
      expect(channelIdInPath('/channels/'), isNull);
      expect(channelIdInPath('/settings'), isNull);
    });

    test('a message link is its channel, not channel/m/message', () {
      expect(channelIdInPath(Routes.message('c1', 'm1')), 'c1');
      expect(channelIdInPath('/channels/c1/'), 'c1');
    });
  });
}
