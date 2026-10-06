// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `IncomingCallOverlay`: rendered above the routed tree regardless of
/// window width or which route is current, both actions reachable at every
/// width, Escape declines, accept both opens the DM's call pane and
/// navigates there, and a new ring raises and focuses the desktop window.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/providers/dm_call_ring_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/user_profiles.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/dm_call_pane.dart';
import 'package:slimm_app/src/widgets/incoming_call_overlay.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'desktop/support/fake_desktop_window_port.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Real ring/timeout logic, network calls swapped out: [decline] would
/// otherwise reach a server that does not exist here.
class _TestDmCallRingController extends DmCallRingController {
  _TestDmCallRingController(super.ref);

  int declineCalls = 0;

  @override
  Future<void> ensureChannelLoaded(String channelId) async {}

  @override
  Future<void> decline(IncomingDmCallRing ring) async {
    declineCalls++;
    dismissIncoming();
  }
}

GoRouter _router() => GoRouter(
  initialLocation: '/channels',
  routes: [
    GoRoute(path: '/channels', builder: (_, __) => const Placeholder()),
    GoRoute(
      path: Routes.channelPattern,
      builder: (_, __) => const Placeholder(),
    ),
  ],
);

String _where(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.toString();

class _Setup {
  _Setup(this.container, this.events, this.ring, this.router);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final _TestDmCallRingController ring;
  final GoRouter router;
}

Future<_Setup> _pump(WidgetTester tester, {double width = 1200}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final router = _router();
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  late _TestDmCallRingController ringController;

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events.stream),
      routerProvider.overrideWithValue(router),
      dmCallRingControllerProvider.overrideWith((ref) {
        ringController = _TestDmCallRingController(ref);
        return ringController;
      }),
      userProfileProvider('caller-1').overrideWith(
        (ref) async => const api.UserProfile(
          id: 'caller-1',
          username: 'alice',
          displayName: 'Alice',
          createdAt: 0,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
        builder: (context, child) =>
            Stack(children: [child!, const IncomingCallOverlay()]),
      ),
    ),
  );
  await tester.pump();

  return _Setup(container, events, ringController, router);
}

void _emitRing(_Setup s) => s.events.add(
  const api.CallRinging(
    channelId: 'dm-1',
    ringId: 'ring-1',
    callerId: 'caller-1',
  ),
);

void main() {
  testWidgets('nothing renders while no ring is incoming', (tester) async {
    await _pump(tester);
    expect(find.text('Incoming call'), findsNothing);
  });

  testWidgets('a wide window shows the caller and both actions', (
    tester,
  ) async {
    final s = await _pump(tester, width: 1200);
    _emitRing(s);
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Incoming call'), findsOneWidget);
    expect(find.bySemanticsLabel('Decline'), findsOneWidget);
    expect(find.bySemanticsLabel('Accept'), findsOneWidget);
  });

  testWidgets('a compact window still shows both actions', (tester) async {
    final s = await _pump(tester, width: 400);
    _emitRing(s);
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.bySemanticsLabel('Decline'), findsOneWidget);
    expect(find.bySemanticsLabel('Accept'), findsOneWidget);
  });

  testWidgets('accepting opens the DM call pane and navigates there', (
    tester,
  ) async {
    final s = await _pump(tester);
    _emitRing(s);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Accept'));
    await tester.pumpAndSettle();

    expect(s.container.read(dmCallOpenProvider), 'dm-1');
    expect(_where(s.router), Routes.channel('dm-1'));
    expect(
      find.text('Incoming call'),
      findsNothing,
      reason: 'accepting dismisses the ring the same way the old banner did',
    );
  });

  testWidgets('declining reaches the ring controller and clears the overlay', (
    tester,
  ) async {
    final s = await _pump(tester);
    _emitRing(s);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Decline'));
    await tester.pumpAndSettle();

    expect(s.ring.declineCalls, 1);
    expect(find.text('Incoming call'), findsNothing);
  });

  testWidgets('Escape declines with no tab stop needed first', (tester) async {
    final s = await _pump(tester);
    _emitRing(s);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(s.ring.declineCalls, 1);
    expect(find.text('Incoming call'), findsNothing);
  });

  testWidgets('a new ring raises and focuses an active desktop window', (
    tester,
  ) async {
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    DesktopWindowShell.debugActivate();
    addTearDown(DesktopWindowShell.debugReset);

    final s = await _pump(tester);
    expect(port.showCalls, 0);
    expect(port.focusCalls, 0);

    _emitRing(s);
    await tester.pumpAndSettle();

    expect(port.showCalls, 1);
    expect(port.focusCalls, 1);
  });

  testWidgets('an inactive desktop shell is never asked to focus anything', (
    tester,
  ) async {
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    addTearDown(DesktopWindowShell.debugReset);

    final s = await _pump(tester);
    _emitRing(s);
    await tester.pumpAndSettle();

    expect(port.showCalls, 0);
    expect(port.focusCalls, 0);
  });
}
