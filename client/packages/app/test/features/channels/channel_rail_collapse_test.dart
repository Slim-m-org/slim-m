// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Folding a category from its header in the real rail sections.
///
/// The owner reported no way to collapse channels under their category: the
/// fold state existed but was reachable only from a manager's right-click
/// menu, with nothing on the header saying it could fold. Pressing the header
/// is the verb now, for a manager and a plain member alike.
library;

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/collapsed_categories_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Channel _channel(String id, {int lastRead = 0, int mentioned = 0}) => Channel(
  id: id,
  name: id,
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: mentioned,
  lastReadSeq: lastRead,
  mentionedSeq: mentioned,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  categoryId: 'cat1',
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required List<Channel> channels,
  String? selectedId,
  bool canManage = false,
  Set<String> collapsedAtStart = const {},
  bool inLabelledGroup = false,
}) async {
  SharedPreferences.setMockInitialValues({
    if (collapsedAtStart.isNotEmpty)
      collapsedCategoriesKey: collapsedAtStart.toList(),
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      preferencesProvider.overrideWith(
        (ref) => SharedPreferences.getInstance(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: _maybeGrouped(
            inLabelledGroup,
            ChannelCategorySections(
              channels: channels,
              categories: const [
                ChannelCategoryRow(id: 'cat1', name: 'Lounge', position: 0),
              ],
              selectedId: selectedId,
              canManage: canManage,
              onReorder: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// The rail's rows sit under an ancestor that is itself a semantics node, and
/// a header that is not its own node is merged into that ancestor's label.
Widget _maybeGrouped(bool grouped, Widget child) =>
    grouped ? Semantics(container: true, label: 'rail', child: child) : child;

Future<void> _pressHeader(WidgetTester tester) async {
  await tester.tap(find.text('Lounge'));
  await tester.pumpAndSettle();
}

/// A folded row is replaced by a zero-size box, so its text leaves the tree.
bool _shown(WidgetTester tester, String name) =>
    find.text(name).evaluate().isNotEmpty;

void main() {
  testWidgets('pressing the header hides its channels, and again shows them', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      channels: [_channel('alpha'), _channel('beta')],
    );
    expect(_shown(tester, 'alpha'), isTrue);
    final openBottom = tester.getBottomLeft(find.text('Lounge')).dy;

    await _pressHeader(tester);

    expect(_shown(tester, 'alpha'), isFalse);
    expect(_shown(tester, 'beta'), isFalse);
    expect(container.read(collapsedCategoriesProvider), {'cat1'});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(collapsedCategoriesKey), ['cat1']);
    expect(
      tester.getBottomLeft(find.text('Lounge')).dy,
      openBottom,
      reason: 'the header itself must not move when its rows fold away',
    );

    await _pressHeader(tester);

    expect(_shown(tester, 'alpha'), isTrue);
    expect(container.read(collapsedCategoriesProvider), isEmpty);
    expect(prefs.getStringList(collapsedCategoriesKey), isEmpty);
  });

  testWidgets('a manager can fold from the header too', (tester) async {
    await _pump(tester, channels: [_channel('alpha')], canManage: true);

    await _pressHeader(tester);

    expect(_shown(tester, 'alpha'), isFalse);
  });

  testWidgets('a fold stored on this device is honoured on first paint', (
    tester,
  ) async {
    await _pump(
      tester,
      channels: [_channel('alpha')],
      collapsedAtStart: {'cat1'},
    );

    expect(_shown(tester, 'alpha'), isFalse);
  });

  testWidgets('a folded category still shows the selected channel', (
    tester,
  ) async {
    await _pump(
      tester,
      channels: [_channel('alpha'), _channel('beta')],
      selectedId: 'beta',
      collapsedAtStart: {'cat1'},
    );

    expect(_shown(tester, 'beta'), isTrue);
    expect(_shown(tester, 'alpha'), isFalse);
  });

  testWidgets('a folded category still shows a channel with unread mentions', (
    tester,
  ) async {
    await _pump(
      tester,
      channels: [
        _channel('alpha'),
        _channel('beta', mentioned: 4),
        _channel('gamma', lastRead: 4, mentioned: 4),
      ],
      collapsedAtStart: {'cat1'},
    );

    expect(_shown(tester, 'beta'), isTrue);
    expect(_shown(tester, 'alpha'), isFalse, reason: 'nothing to surface');
    expect(_shown(tester, 'gamma'), isFalse, reason: 'mention already read');
  });

  testWidgets('the chevron turns from down to right and sits on the text', (
    tester,
  ) async {
    await _pump(tester, channels: [_channel('alpha')]);
    final chevron = find.byIcon(AppIcons.chevronDown);
    double turns() =>
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns;

    expect(turns(), 0);
    final text = tester.getCenter(find.text('Lounge'));
    final glyph = tester.getCenter(chevron);
    expect(glyph.dy, closeTo(text.dy, 0.5));
    expect(
      tester.getTopRight(chevron).dx,
      lessThan(tester.getTopLeft(find.text('Lounge')).dx),
    );

    await _pressHeader(tester);

    expect(turns(), -0.25);
  });

  testWidgets('the header is a labelled button that Enter folds', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, channels: [_channel('alpha')]);

    SemanticsNode node() =>
        tester.getSemantics(find.bySemanticsLabel('Lounge'));
    expect(node().hint, 'Collapse');
    expect(node().flagsCollection.isButton, isTrue);
    expect(
      node().flagsCollection.isHeader,
      isFalse,
      reason:
          'the web engine turns a header into a plain h2, losing the button',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(_shown(tester, 'alpha'), isFalse);
    expect(node().hint, 'Expand');
    semantics.dispose();
  });

  testWidgets('inside a labelled group the header is still its own named, '
      'expandable node', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, channels: [_channel('alpha')], inLabelledGroup: true);

    SemanticsNode node() =>
        tester.getSemantics(find.bySemanticsLabel('Lounge'));
    expect(node().label, 'Lounge');
    expect(node().flagsCollection.isButton, isTrue);
    expect(node().flagsCollection.isHeader, isFalse);
    expect(node().flagsCollection.isExpanded, Tristate.isTrue);

    await _pressHeader(tester);

    expect(node().flagsCollection.isExpanded, Tristate.isFalse);
    semantics.dispose();
  });
}
