// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone's call strip for a call another community's account holds: it
/// names that community and drives that call, and the floating call pill,
/// which covered the offline bar under the app bar, steps aside for it.
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
Future<void> _pumpShell(WidgetTester tester, AccountFixture here) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
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

void main() {
  setUpAll(loadRealFonts);

  final strip = find.byKey(voiceStripKey);

  testWidgets('a call in another community is the strip, so the pill no '
      'longer covers the offline bar', (tester) async {
    final other = (await tester.runAsync(otherCommunityInCall))!;
    final here = await hereWithCallElsewhere(
      other,
      extraOverrides: [
        syncControllerProvider.overrideWith(
          (ref) => StubSyncController(ref, SyncStatus.offline),
        ),
      ],
    );
    await _pumpShell(tester, here);

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
    await _pumpShell(tester, here);

    await tester.tap(find.bySemanticsLabel('Return to call, lounge on Beta'));
    await pumpFrames(tester);
    expect(host.switched, [otherCommunity.origin]);
    expect(other.container.read(dmCallOpenProvider), 'c-lounge');
    expect(
      router.routeInformationProvider.value.uri.path,
      '/channels/c-lounge',
    );

    await tester.tap(
      find.descendant(of: strip, matching: find.bySemanticsLabel('Mute')),
    );
    await pumpFrames(tester);
    expect(
      find.descendant(of: strip, matching: find.bySemanticsLabel('Unmute')),
      findsOneWidget,
      reason: "the toggle follows the other account's own call",
    );

    await tester.tap(
      find.descendant(of: strip, matching: find.bySemanticsLabel('Leave call')),
    );
    await pumpFrames(tester);
    expect(
      other.container.read(voiceControllerProvider).state,
      VoiceSessionState.idle,
    );

    await teardownBoth(tester, here, other);
  });
}
