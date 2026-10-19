// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call tile says so, quietly, when someone's audio is breaking up, and says
/// nothing while it is fine.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/call_health_format.dart';
import 'package:slimm_app/src/features/settings/widgets/call_health_row.dart';
import 'package:slimm_app/src/features/voice/providers/voice_health.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';

const _bob = VoiceParticipant(
  identity: 'user-bob',
  name: 'Bob',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

Widget _app(Widget child, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    );

class _HealthyTile extends ConsumerWidget {
  const _HealthyTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) => CallParticipantTile(
    participant: _bob,
    poorConnection: ref.watch(poorConnectionsProvider).contains(_bob.identity),
  );
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('a healthy tile shows no hint', (tester) async {
    await tester.pumpWidget(_app(const CallParticipantTile(participant: _bob)));
    expect(find.byKey(poorConnectionBadgeKey), findsNothing);
  });

  testWidgets('a poor connection shows the hint and names it to a reader', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(const CallParticipantTile(participant: _bob, poorConnection: true)),
    );
    expect(find.byKey(poorConnectionBadgeKey), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('connection is unstable')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('the hint follows the health model and goes away again', (
    tester,
  ) async {
    final poor = ValueNotifier<Set<String>>({});
    await tester.pumpWidget(
      _app(
        const _HealthyTile(),
        overrides: [
          poorConnectionsProvider.overrideWith((ref) => ListenableState(poor)),
        ],
      ),
    );
    expect(find.byKey(poorConnectionBadgeKey), findsNothing);
    poor.value = {'user-bob'};
    await tester.pump();
    expect(find.byKey(poorConnectionBadgeKey), findsOneWidget);
    poor.value = {};
    await tester.pump();
    expect(find.byKey(poorConnectionBadgeKey), findsNothing);
  });

  group('the last call on the Troubleshooting page', () {
    final summary = CallHealthSummary.of(
      endedAt: DateTime(2026),
      remote: {
        'Bob': [
          const HealthInterval(
            seconds: 5,
            samples: 240000,
            concealedSamples: 2400,
            bufferMs: 42,
            rttMs: 23,
          ),
        ],
      },
    );

    testWidgets('says so before any call has ended', (tester) async {
      await tester.pumpWidget(
        _app(
          const CallHealthRow(),
          overrides: [
            lastCallHealthProvider.overrideWith(
              (ref) => ListenableState<CallHealthSummary?>(ValueNotifier(null)),
            ),
          ],
        ),
      );
      expect(find.text('Numbers appear here after a call.'), findsOneWidget);
    });

    testWidgets('shows the medians and the worst of the last call', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const CallHealthRow(),
          overrides: [
            lastCallHealthProvider.overrideWith(
              (ref) =>
                  ListenableState<CallHealthSummary?>(ValueNotifier(summary)),
            ),
          ],
        ),
      );
      expect(find.text('Breaking up: 1.0% median, 1.0% worst'), findsOneWidget);
      expect(
        find.text('Round trip: 23 ms median, 23 ms worst'),
        findsOneWidget,
      );
    });

    test('a measure with no samples says so instead of zero', () {
      final lines = describeCallHealth(
        CallHealthSummary.of(endedAt: DateTime(2026), remote: {}).remote,
      );
      expect(lines, everyElement(endsWith('no data')));
    });
  });
}
