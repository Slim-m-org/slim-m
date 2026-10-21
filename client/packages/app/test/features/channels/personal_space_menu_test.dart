// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the personal space row's own kebab: it opens a menu with one
/// action, that action hides the row, and hiding it says how to get it
/// back rather than vanishing silently.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_space_menu.dart';
import 'package:slimm_app/src/widgets/toast_overlay.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container() => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    databaseProvider.overrideWith((ref) async {
      final db = SlimmDatabase(NativeDatabase.memory());
      ref.onDispose(db.close);
      return db;
    }),
    mockApiOverride(
      (request) async =>
          throw StateError('unexpected request in this test: ${request.url}'),
    ),
  ],
);

Widget _harness(ProviderContainer container, List<Channel> channels) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: DirectMessagesSection(channels: channels, selectedId: null),
        ),
        builder: (context, child) => Stack(
          children: [
            child ?? const SizedBox.shrink(),
            const Positioned.fill(child: ToastOverlay()),
          ],
        ),
      ),
    );

const _personal = Channel(
  id: 'dm-self',
  name: personalSpaceName,
  kind: dmChannelKind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: true,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// The kebab sits inside a row that paints its own selection and hover
  /// tint, so it must not paint a second one of its own on top: that lands a
  /// `surfaceRaised` circle over a fill the row chose, at a colour the row
  /// never accounted for, and the circle reads as a patch that does not match
  /// the channel around it. Reported exactly that way.
  ///
  /// Every other kebab in the app already passes this - the rail's own does -
  /// and this one was the single call site that did not.
  testWidgets('the kebab lets the row own the hover tint', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(_harness(container, [_personal]));
    await tester.pumpAndSettle();

    final button = tester.widget<AppIconButton>(
      find.byWidgetPredicate(
        (w) => w is AppIconButton && w.icon == AppIcons.moreVertical,
      ),
    );
    expect(
      button.suppressOwnHoverFill,
      isTrue,
      reason:
          'left false, its own surfaceRaised circle sits on top of the '
          "row's tint at a colour that row never chose",
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an existing personal space carries a kebab with one action', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(_harness(container, [_personal]));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Personal space options'));
    await tester.pumpAndSettle();

    expect(find.text('Remove from list'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a personal space that has never been opened carries no kebab at all',
    (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await tester.pumpWidget(_harness(container, const []));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Personal space options'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'choosing "Remove from list" hides the row and names the way back',
    (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await tester.pumpWidget(_harness(container, [_personal]));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Personal space options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from list'));
      await tester.pumpAndSettle();

      expect(
        find.text(personalSpaceName),
        findsNothing,
        reason: 'the row itself must be gone, not merely its menu closed',
      );
      expect(find.text(personalSpaceHiddenNotice), findsOneWidget);
      // Drains the toast's own dismiss timer so it is not still pending once this test tears down.
      await tester.pump(const Duration(seconds: 5));

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the hidden flag is keyed by account: signing in as somebody else on '
    'the same device does not inherit it',
    (tester) async {
      final first = _container();
      addTearDown(first.dispose);
      await tester.pumpWidget(_harness(first, [_personal]));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Personal space options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from list'));
      await tester.pumpAndSettle();
      expect(find.text(personalSpaceName), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
      first.dispose();

      const otherTokens = api.TokenPair(
        userId: 'other',
        accessToken: 'access-2',
        refreshToken: 'refresh-2',
        accessExpiresAt: 0,
      );
      final second = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(
            api.SessionStore(tokens: otherTokens),
          ),
          databaseProvider.overrideWith((ref) async {
            final db = SlimmDatabase(NativeDatabase.memory());
            ref.onDispose(db.close);
            return db;
          }),
        ],
      );
      addTearDown(second.dispose);
      await tester.pumpWidget(_harness(second, [_personal]));
      await tester.pumpAndSettle();

      expect(
        find.text(personalSpaceName),
        findsOneWidget,
        reason:
            'a second account\'s own personal space must open visible, '
            'never pre-hidden by the first account\'s choice',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );
}
