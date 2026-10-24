// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The cards a video tile shows instead of a picture: each remote share state,
/// a stalled share over its dimmed last frame, and the paused local preview.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/video_pause.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_app/src/features/voice/widgets/local_preview_gate.dart';
import 'package:slimm_app/src/features/voice/widgets/video_health_overlay.dart';
import 'package:slimm_app/src/features/voice/widgets/video_state_card.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

Widget _app(Widget child) => ProviderScope(
  overrides: [
    preferencesProvider.overrideWith((ref) => SharedPreferences.getInstance()),
    pauseOnUnfocusedAppliesProvider.overrideWithValue(true),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: SizedBox(width: 320, height: 180, child: child),
  ),
);

Future<void> _lifecycle(WidgetTester tester, AppLifecycleState state) async {
  TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(state);
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('remote screen share states', () {
    for (final (status, title, line) in [
      (
        ScreenShareStatus.loading,
        'Loading screen share',
        "Waiting for Bob's first frame",
      ),
      (
        ScreenShareStatus.resuming,
        'Resuming screen share',
        "Catching up with Bob's share",
      ),
      (
        ScreenShareStatus.paused,
        'Share paused',
        'Bob paused their screen share',
      ),
      (ScreenShareStatus.ended, 'Share ended', 'Bob stopped sharing'),
    ]) {
      testWidgets('$status shows the sharer and says why', (tester) async {
        await tester.pumpWidget(
          _app(
            Builder(
              builder: (context) => screenShareStatusCard(
                context: context,
                status: status,
                identity: 'bob',
                name: 'Bob',
              ),
            ),
          ),
        );
        expect(find.text(title), findsOneWidget);
        expect(find.text(line), findsOneWidget);
        expect(find.bySemanticsLabel('$title. $line'), findsOneWidget);
      });
    }
  });

  group('stalled screen share', () {
    for (final (state, title) in [
      (VideoTileHealth.stalled, 'Reconnecting screen share'),
      (VideoTileHealth.stopped, 'Not being captured'),
    ]) {
      testWidgets('$state keeps the last frame mounted under a card', (
        tester,
      ) async {
        final health = ValueNotifier({'screen:bob': state});
        await tester.pumpWidget(
          _app(
            VideoHealthOverlay(
              health: health,
              tileKey: 'screen:bob',
              sharerName: 'Bob',
              sharerIdentity: 'bob',
              child: const ColoredBox(color: Colors.green, key: Key('frame')),
            ),
          ),
        );
        expect(find.byKey(const Key('frame')), findsOneWidget);
        expect(find.text(title), findsOneWidget);
        final card = tester.widget<VideoStateCard>(find.byType(VideoStateCard));
        expect(card.dimsVideoBehind, isTrue);
      });
    }
  });

  group('local preview gate', () {
    Widget gate() => _app(
      const LocalPreviewGate(
        identity: 'me',
        name: 'Me',
        screenShare: true,
        child: ColoredBox(color: Colors.green, key: Key('preview')),
      ),
    );

    testWidgets('an unfocused window keeps the preview', (tester) async {
      await tester.pumpWidget(gate());
      await tester.pump();
      await _lifecycle(tester, AppLifecycleState.inactive);
      expect(find.byKey(const Key('preview')), findsOneWidget);
    });

    testWidgets('a minimised window shows a card, not black', (tester) async {
      await tester.pumpWidget(gate());
      await tester.pump();
      final life = ProviderScope.containerOf(
        tester.element(find.byType(LocalPreviewGate)),
      ).read(appLifecycleProvider.notifier);

      life.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      expect(find.byKey(const Key('preview')), findsNothing);
      expect(find.text('Preview paused while minimised'), findsOneWidget);

      life.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const Key('preview')), findsOneWidget);
    });
  });
}
