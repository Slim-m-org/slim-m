// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Our own bad connection is a banner in the call stage's flow (desktop-vs-
/// mobile rule 6), shown while the health model flags us and not otherwise.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_health.dart';
import 'package:slimm_app/src/features/voice/widgets/poor_connection_banner.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

VoiceParticipant _who(String id, {bool local = false}) => VoiceParticipant(
  identity: id,
  name: id,
  isSpeaking: false,
  isMuted: false,
  isLocal: local,
  isScreenSharing: false,
);

Future<ValueNotifier<Set<String>>> _pump(
  WidgetTester tester,
  Set<String> poor,
) async {
  final notifier = ValueNotifier<Set<String>>(poor);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        voiceParticipantsProvider.overrideWithValue([
          _who('me', local: true),
          _who('bob'),
        ]),
        poorConnectionsProvider.overrideWith(
          (ref) => ListenableState(notifier),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: Column(children: [PoorConnectionBanner(), Text('below')]),
        ),
      ),
    ),
  );
  return notifier;
}

void main() {
  const text = 'Your connection is unstable.';

  testWidgets('nothing shows while all is well', (tester) async {
    await _pump(tester, {});
    expect(find.text(text), findsNothing);
  });

  testWidgets('our own bad connection pushes content down in a banner', (
    tester,
  ) async {
    await _pump(tester, {'me'});
    expect(find.text(text), findsOneWidget);
    final banner = tester.getRect(find.byKey(poorConnectionBannerKey));
    expect(
      tester.getTopLeft(find.text('below')).dy,
      greaterThan(banner.bottom - 1),
    );
  });

  testWidgets('someone else being poor is not our banner', (tester) async {
    await _pump(tester, {'bob'});
    expect(find.text(text), findsNothing);
  });

  testWidgets('the banner goes away when the connection recovers', (
    tester,
  ) async {
    final poor = await _pump(tester, {'me'});
    expect(find.text(text), findsOneWidget);
    poor.value = {};
    await tester.pump();
    expect(find.text(text), findsNothing);
  });

  testWidgets('the call stage carries it above the tiles', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final harness = VoiceHarness();
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      extraOverrides: [
        voiceRosterProvider.overrideWith(
          (ref, channelId) =>
              const Stream<List<VoiceRosterParticipant>>.empty(),
        ),
        poorConnectionsProvider.overrideWith(
          (ref) => ListenableState(ValueNotifier({'me'})),
        ),
      ],
    );
    addTearDown(harness.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: VoiceScreen(channelId: 'channel-1')),
        ),
      ),
    );
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await tester.pump();
    session.emitParticipants([_who('me', local: true), _who('bob')]);
    await tester.pump(const Duration(seconds: 1));

    final banner = tester.getRect(find.text(text));
    final tile = tester.getRect(find.text('bob'));
    expect(banner.bottom, lessThan(tile.top));
    await harness.container.read(voiceControllerProvider.notifier).leave();
  });
}
