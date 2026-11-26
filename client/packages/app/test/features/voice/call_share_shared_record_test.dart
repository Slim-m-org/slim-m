// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call screen and the rail's call bar each run a share flow; both read one
/// call-scoped record, so a share started in one shows its source in the other
/// and a second start is refused while one is still choosing a source.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/call_share_memory.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/call_share_flow.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_voice.dart';
import '../../ui_snapshot_support.dart';
import 'voice_call_controls_harness.dart' show InertSession;

const _screen = ScreenShareSource(id: 's1', name: 'Screen 1');
const _other = ScreenShareSource(id: 's2', name: 'Screen 2');

final _live = VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  connectedAt: DateTime.now().subtract(const Duration(minutes: 3)),
);

/// A stand-in for one place that owns a share flow: the call screen or the rail.
class _Place extends ConsumerStatefulWidget {
  const _Place({required this.onFlow});

  final void Function(CallShareFlow flow, BuildContext context) onFlow;

  @override
  ConsumerState<_Place> createState() => _PlaceState();
}

class _PlaceState extends ConsumerState<_Place> {
  late final _flow = CallShareFlow(
    ref: ref,
    controller: () => ref.read(voiceControllerProvider.notifier),
    voice: () => VoiceFlags.from(ref.read(voiceControllerProvider)),
    mounted: () => mounted,
    changed: setState,
  );

  @override
  Widget build(BuildContext context) {
    widget.onFlow(_flow, context);
    return const SizedBox();
  }
}

void main() {
  setUpAll(loadRealFonts);

  Future<void> withTwoPlaces(
    WidgetTester tester,
    InertSession session,
    Future<void> Function(
      (CallShareFlow, BuildContext) rail,
      (CallShareFlow, BuildContext) call,
    )
    body,
  ) async {
    final fixture = await fixtureContainer(
      extraOverrides: [
        voiceControllerProvider.overrideWith(
          (ref) => FakeVoiceController(
            ref,
            initial: _live,
            session: session,
            recording: true,
          ),
        ),
      ],
    );
    late (CallShareFlow, BuildContext) rail;
    late (CallShareFlow, BuildContext) call;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Column(
              children: [
                _Place(onFlow: (f, c) => rail = (f, c)),
                _Place(onFlow: (f, c) => call = (f, c)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await withFixtureTeardown(tester, fixture, () => body(rail, call));
  }

  testWidgets('a share started from the rail shows its source on the call '
      'screen', (tester) async {
    final session = InertSession(
      needsSource: true,
      sources: Future.value([_screen, _other]),
    );
    await withTwoPlaces(tester, session, (rail, call) async {
      expect(call.$1.lastSource, isNull);
      rail.$1.pick(rail.$2, _screen);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(call.$1.lastSource, _screen);
    });
  });

  testWidgets(
    'a second start is refused while the other is choosing a source',
    (tester) async {
      final session = InertSession(
        needsSource: true,
        sources: Future.value([_screen, _other]),
      );
      await withTwoPlaces(tester, session, (rail, call) async {
        rail.$1.toggle(rail.$2);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(session.sourceFetchCount, 1);

        call.$1.toggle(call.$2);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(session.sourceFetchCount, 1, reason: 'one picker at a time');
        expect(
          ProviderScope.containerOf(
            call.$2,
          ).read(callShareMemoryProvider).inFlight,
          isTrue,
        );
      });
    },
  );

  testWidgets('the record is forgotten when the call changes', (tester) async {
    final session = InertSession(
      needsSource: true,
      sources: Future.value([_screen]),
    );
    await withTwoPlaces(tester, session, (rail, call) async {
      rail.$1.pick(rail.$2, _screen);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final container = ProviderScope.containerOf(call.$2);
      (container.read(voiceControllerProvider.notifier) as FakeVoiceController)
          .connect(channelId: 'c-next');
      await tester.pump();
      expect(call.$1.lastSource, isNull);
    });
  });
}
