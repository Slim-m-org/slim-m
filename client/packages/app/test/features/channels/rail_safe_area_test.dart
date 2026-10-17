// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests that the rail's header keeps its content clear of the status-bar
/// inset while its background and border still reach the screen edge.
///
/// Both halves matter and they pull in opposite directions.
/// Inset the whole bar and a scaffold-coloured band appears above the rail;
/// inset nothing and the server name paints under the notch, which is what
/// this app shipped before.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

/// The insets of an iPhone with a notch, in logical points: 59 for the
/// status bar, 34 for the home indicator.
const double _topInset = 59;
const double _bottomInset = 34;
const double _dpr = 3;

/// A container wired like the app's, with the network swapped for an
/// always-failing client and the database for an in-memory one, matching
/// `home_shell_test.dart`'s harness; see [_teardown] for the disposal order.
({ProviderContainer container, SlimmDatabase db}) _setup() {
  final db = SlimmDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(
            (_) async => throw StateError('no network in this test'),
          ),
        );
        ref.onDispose(api.close);
        return api;
      }),
      databaseProvider.overrideWith((ref) => db),
    ],
  );
  return (container: container, db: db);
}

/// Unmounts before disposing so drift's query-stream cache timer has expired
/// by the time the database closes, exactly as `home_shell_test.dart` does.
Future<void> _teardown(
  WidgetTester tester,
  ProviderContainer container,
  SlimmDatabase db,
) async {
  await tester.pumpWidget(const SizedBox());
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
  await db.close();
}

/// Bypasses the real router, which would redirect a signed-out session to
/// onboarding rather than showing the rail.
GoRouter _testRouter() => GoRouter(
  initialLocation: '/channels',
  routes: [
    GoRoute(
      path: '/channels',
      builder: (context, state) =>
          const HomeShell(child: Center(child: Text('conversation'))),
    ),
  ],
);

/// Pumps the shell at [width] logical points on a view that reports notch
/// and home-indicator insets.
Future<void> _pumpWithInsets(
  WidgetTester tester,
  ProviderContainer container,
  double width,
) async {
  tester.view.physicalSize = Size(width * _dpr, 932 * _dpr);
  tester.view.devicePixelRatio = _dpr;
  tester.view.padding = const FakeViewPadding(
    top: _topInset * _dpr,
    bottom: _bottomInset * _dpr,
  );
  tester.view.viewPadding = const FakeViewPadding(
    top: _topInset * _dpr,
    bottom: _bottomInset * _dpr,
  );
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: _testRouter(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The server name line, which falls back to 'slim-m' when `/version` fails
/// as it does here. Standing in for the header's content as a whole.
Finder _headerContent() =>
    find.descendant(of: find.byType(RailHeader), matching: find.text('slim-m'));

/// The header's own painted background, which its [Container] builds as the
/// outermost [DecoratedBox] under [RailHeader].
///
/// Asserting on [RailHeader] itself cannot see this: a [SafeArea] wrapping the
/// whole bar contributes its own [Padding] render box, whose top is 0 either
/// way, so the vacuous form of this test passed against the very mistake it
/// names. The decoration is the thing that has to reach the edge.
Finder _headerBackground() => find
    .descendant(
      of: find.byType(RailHeader),
      matching: find.byType(DecoratedBox),
    )
    .first;

void main() {
  testWidgets('the rail header insets its content below the status bar', (
    tester,
  ) async {
    final setup = _setup();
    await _pumpWithInsets(tester, setup.container, 430);

    expect(
      tester.getRect(_headerContent()).top,
      greaterThanOrEqualTo(_topInset),
      reason: 'the server name must not paint under the notch',
    );

    await _teardown(tester, setup.container, setup.db);
  });

  testWidgets('the rail header background still reaches the screen edge', (
    tester,
  ) async {
    final setup = _setup();
    await _pumpWithInsets(tester, setup.container, 430);

    expect(
      tester.getRect(_headerBackground()).top,
      0.0,
      reason:
          'insetting the bar itself would leave a scaffold-coloured '
          'band above the rail',
    );
    expect(
      tester.getRect(_headerBackground()).top,
      lessThan(tester.getRect(_headerContent()).top),
      reason:
          'the background has to extend above the content it insets, '
          'or nothing is painted behind the status bar',
    );

    await _teardown(tester, setup.container, setup.db);
  });

  testWidgets('the inset applies at expanded width too', (tester) async {
    final setup = _setup();
    await _pumpWithInsets(tester, setup.container, 1400);

    expect(
      tester.getRect(_headerContent()).top,
      greaterThanOrEqualTo(_topInset),
    );
    expect(tester.getRect(_headerBackground()).top, 0.0);

    await _teardown(tester, setup.container, setup.db);
  });
}
