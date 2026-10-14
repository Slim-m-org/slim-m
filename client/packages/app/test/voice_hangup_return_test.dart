// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Owner: the rejoin screen after hanging up on a phone is a "useless
/// screen, just return me to channel view or last text channel". Driven
/// through the real shell and `VoiceScreen`: an explicit hang-up on a phone
/// lands on the previous text channel with a recap toast, a dropped call
/// keeps the rejoin screen, and a wide window keeps the stage.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/call_recap.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/channel_screen.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart' show AppToastSeverity;
import 'package:slimm_rtc/rtc.dart';

import 'home_shell_harness.dart';
import 'voice_controller_harness.dart' show FakeSession;

class _HangUpController extends VoiceController {
  _HangUpController(super.ref) : super(session: FakeSession());

  @override
  Future<void> join(String channelId) async {
    state = VoiceState(
      state: VoiceSessionState.connected,
      channelId: channelId,
    );
  }

  @override
  Future<void> leave() async {
    final channelId = state.channelId!;
    final now = DateTime.now();
    state = VoiceState(
      recap: CallRecap(
        channelId: channelId,
        startedAt: now.subtract(const Duration(seconds: 42)),
        endedAt: now,
        others: const [],
        sharedScreen: false,
        usedCamera: false,
      ),
      justLeftChannelId: channelId,
      justLeftAt: now,
    );
  }

  void drop(String channelId) {
    state = VoiceState(
      state: VoiceSessionState.failed,
      channelId: channelId,
      error: 'Connection lost.',
    );
  }
}

Future<
  ({ProviderContainer container, SlimmDatabase db, _HangUpController voice})
>
_inCall(WidgetTester tester, double width) async {
  late _HangUpController voice;
  final s = setup(
    httpClient: quietClient(),
    signedIn: true,
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => voice = _HangUpController(ref),
      ),
    ],
  );
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 't1', name: 'general', kind: 'text', createdAt: 0),
    const api.Channel(id: 'c1', name: 'lounge', kind: 'voice', createdAt: 1),
  ]);
  await pumpAtWidth(tester, s.container, width, location: Routes.channel('t1'));
  tester.element(find.byType(HomeShell)).go(Routes.channel('c1'));
  await tester.pumpAndSettle();
  return (container: s.container, db: s.db, voice: voice);
}

String _location(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(HomeShell))).state.uri.toString();

void main() {
  testWidgets('a phone hang-up lands on the last text channel with a recap '
      'toast', (tester) async {
    final s = await _inCall(tester, 390);
    expect(_location(tester), Routes.channel('c1'));

    await s.voice.leave();
    await tester.pumpAndSettle();

    expect(_location(tester), Routes.channel('t1'));
    expect(find.byType(ChannelScreen), findsOneWidget);
    expect(find.text('Join muted'), findsNothing);
    final toasts = s.container.read(toastsProvider);
    expect(toasts.single.message, 'Call ended - 42 sec.');
    expect(toasts.single.severity, AppToastSeverity.success);

    await teardown(tester, s.container, s.db);
  });

  testWidgets(
    'with no text channel seen yet a phone hang-up lands on the list',
    (tester) async {
      late _HangUpController voice;
      final s = setup(
        httpClient: quietClient(),
        signedIn: true,
        extraOverrides: [
          voiceControllerProvider.overrideWith(
            (ref) => voice = _HangUpController(ref),
          ),
        ],
      );
      await MessageStore(s.db).upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'lounge',
          kind: 'voice',
          createdAt: 1,
        ),
      ]);
      await pumpAtWidth(
        tester,
        s.container,
        390,
        location: Routes.channel('c1'),
      );

      await voice.leave();
      await tester.pumpAndSettle();

      expect(_location(tester), Routes.channels);

      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets('a dropped call on a phone still shows the rejoin screen', (
    tester,
  ) async {
    final s = await _inCall(tester, 390);

    s.voice.drop('c1');
    await tester.pumpAndSettle();

    expect(_location(tester), Routes.channel('c1'));
    expect(find.text('Connection lost.'), findsOneWidget);
    expect(s.container.read(toastsProvider), isEmpty);

    await teardown(tester, s.container, s.db);
  });

  testWidgets('a hang-up on a wide window keeps the stage', (tester) async {
    final s = await _inCall(tester, 1400);

    await s.voice.leave();
    await tester.pumpAndSettle();

    expect(_location(tester), Routes.channel('c1'));
    expect(find.text('Join muted'), findsOneWidget);

    await teardown(tester, s.container, s.db);
  });

  for (final width in [390.0, 1400.0]) {
    testWidgets('leaving from another channel still toasts the recap, once, '
        'at $width', (tester) async {
      final s = await _inCall(tester, width);
      tester.element(find.byType(HomeShell)).go(Routes.channel('t1'));
      await tester.pumpAndSettle();

      await s.voice.leave();
      await tester.pumpAndSettle();

      expect(_location(tester), Routes.channel('t1'));
      final toasts = s.container.read(toastsProvider);
      expect(toasts.single.message, 'Call ended - 42 sec.');

      await teardown(tester, s.container, s.db);
    });
  }

  testWidgets('a wide hang-up on the call itself shows the recap card, not a '
      'second toast', (tester) async {
    final s = await _inCall(tester, 1400);

    await s.voice.leave();
    await tester.pumpAndSettle();

    expect(s.container.read(toastsProvider), isEmpty);

    await teardown(tester, s.container, s.db);
  });
}
