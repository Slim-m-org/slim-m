// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone's call strip, and the composer's pill that stands in for it while
/// typing, for a call another community's account holds: each names that
/// community and drives that call, and the floating call pill, which covered
/// the offline bar under the app bar, steps aside for it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/accounts/providers/account_host.dart';
import 'package:slimm_app/src/features/accounts/providers/account_providers.dart';
import 'package:slimm_app/src/features/accounts/providers/account_store.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_call_pill.dart';
import 'package:slimm_app/src/features/voice/widgets/call_keyboard_pill.dart';
import 'package:slimm_app/src/features/voice/providers/dm_call.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_strip_indicator.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/async_wait.dart';
import '../../support/call_elsewhere_fixture.dart';
import '../../support/fake_sync.dart';
import '../../ui_snapshot_support.dart';

/// Records the switch the strip asks for instead of making it.
class _RecordingHost extends AccountHost {
  _RecordingHost()
    : super(
        store: AccountStore(InMemoryKeyStore()),
        createContainer: (_) => throw UnimplementedError(),
        startServices: (_) async {},
        onActivate: (_) async {},
        readSession: (_) async => false,
        signOutRuntime: (_) async {},
      );

  final switched = <String>[];

  @override
  Future<void> switchTo(String origin) async => switched.add(origin);
}

/// The real shell on a phone, in a conversation with the drawer closed, under
/// the app's own chrome, which is where the pill is mounted.
Future<void> _pumpShell(
  WidgetTester tester,
  AccountFixture here, {
  double keyboard = 0,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: here.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: fixtureRouter('/channels/c-general'),
        builder: appChromeBuilder,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  await pumpFrames(tester, frames: 20);
}

/// Beta in a call, seen from here through a host that records the switch, and
/// a router on Beta's account that records where opening the call goes.
typedef _Switchable = ({
  AccountFixture here,
  AccountFixture other,
  _RecordingHost host,
  GoRouter router,
});

Future<_Switchable> _switchable(WidgetTester tester) async {
  final router = GoRouter(
    initialLocation: '/channels/c-general',
    routes: [
      GoRoute(
        path: '/channels/:id',
        builder: (context, state) => const SizedBox.shrink(),
      ),
    ],
  );
  addTearDown(router.dispose);
  final other = (await tester.runAsync(
    () => otherCommunityInCall(
      extraOverrides: [routerProvider.overrideWithValue(router)],
    ),
  ))!;
  final host = _RecordingHost();
  addTearDown(host.dispose);
  final here = await hereWithCallElsewhere(
    other,
    extraOverrides: [accountHostProvider.overrideWithValue(host)],
  );
  return (here: here, other: other, host: host, router: router);
}

/// Here, offline, with Beta's call elsewhere: the bar the floating pill covered.
Future<(AccountFixture, AccountFixture)> _offlineWithCallElsewhere(
  WidgetTester tester, {
  double keyboard = 0,
}) async {
  final other = (await tester.runAsync(otherCommunityInCall))!;
  final here = await hereWithCallElsewhere(
    other,
    extraOverrides: [
      syncControllerProvider.overrideWith(
        (ref) => StubSyncController(ref, SyncStatus.offline),
      ),
    ],
  );
  await _pumpShell(tester, here, keyboard: keyboard);
  return (here, other);
}

/// A press on [place] opens Beta's call there; its mute and leave act on it.
Future<void> _expectDrivesTheCallElsewhere(
  WidgetTester tester,
  Finder place, {
  double keyboard = 0,
}) async {
  final s = await _switchable(tester);
  await _pumpShell(tester, s.here, keyboard: keyboard);

  await tester.tap(
    find.descendant(
      of: place,
      matching: find.bySemanticsLabel('Return to call, lounge on Beta'),
    ),
  );
  await pumpFrames(tester);
  expect(s.host.switched, [otherCommunity.origin]);
  expect(s.other.container.read(dmCallOpenProvider), 'c-lounge');
  expect(
    s.router.routeInformationProvider.value.uri.path,
    '/channels/c-lounge',
  );

  await tester.tap(
    find.descendant(of: place, matching: find.bySemanticsLabel('Mute')),
  );
  await pumpFrames(tester);
  expect(
    find.descendant(of: place, matching: find.bySemanticsLabel('Unmute')),
    findsOneWidget,
    reason: "the toggle follows the other account's own call",
  );

  await tester.tap(
    find.descendant(of: place, matching: find.bySemanticsLabel('Leave call')),
  );
  await pumpFrames(tester);
  expect(
    s.other.container.read(voiceControllerProvider).state,
    VoiceSessionState.idle,
  );

  await teardownBoth(tester, s.here, s.other);
}

void main() {
  setUpAll(loadRealFonts);

  final strip = find.byKey(voiceStripKey);
  final keyboardPill = find.byKey(CallKeyboardPill.pillKey);

  testWidgets('a call in another community is the strip, so the pill no '
      'longer covers the offline bar', (tester) async {
    final (here, other) = await _offlineWithCallElsewhere(tester);

    expect(find.text('Offline, retrying'), findsOneWidget);
    expect(
      find.byKey(AccountCallPill.pillKey),
      findsNothing,
      reason: 'the strip names the same call',
    );
    expect(strip, findsOneWidget);
    expect(find.descendant(of: strip, matching: find.text('lounge')), findsOne);
    expect(
      find.descendant(of: strip, matching: find.text('Beta')),
      findsOneWidget,
      reason: 'the community leads the second line, as on the rail',
    );

    await teardownBoth(tester, here, other);
  });

  testWidgets('a tap switches to that community and opens the call there, '
      "and its controls drive that community's call", (tester) async {
    await _expectDrivesTheCallElsewhere(tester, strip);
  });

  group('with the keyboard up', () {
    testWidgets('the composer pill names the call, so the floating pill '
        'still stays off the offline bar', (tester) async {
      final (here, other) = await _offlineWithCallElsewhere(
        tester,
        keyboard: 300,
      );

      expect(find.text('Offline, retrying'), findsOneWidget);
      expect(strip, findsNothing, reason: 'the strip gives way to the pill');
      expect(keyboardPill, findsOneWidget);
      expect(
        find.descendant(of: keyboardPill, matching: find.text('Beta')),
        findsOneWidget,
        reason: 'the community leads the pill, as it leads the strip',
      );
      expect(
        find.byKey(AccountCallPill.pillKey),
        findsNothing,
        reason: 'the composer pill names the same call',
      );

      await teardownBoth(tester, here, other);
    });

    testWidgets('a tap opens that call there, and the pill drives it', (
      tester,
    ) async {
      await _expectDrivesTheCallElsewhere(tester, keyboardPill, keyboard: 300);
    });
  });
}
