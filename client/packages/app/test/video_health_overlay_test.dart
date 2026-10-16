// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/video_health_overlay.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  late ValueNotifier<Map<String, VideoTileHealth>> health;

  setUp(() => health = ValueNotifier(const {}));

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: SizedBox(
        width: 320,
        height: 180,
        child: VideoHealthOverlay(
          health: health,
          tileKey: 'camera:bob',
          child: const ColoredBox(color: Colors.black, key: Key('video')),
        ),
      ),
    ),
  );

  testWidgets('a playing tile shows only its video', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('video')), findsOneWidget);
    expect(find.text('Paused'), findsNothing);
    expect(find.text('Reconnecting video'), findsNothing);
  });

  testWidgets('each state labels the tile, and the label clears again', (
    tester,
  ) async {
    await pump(tester);
    for (final (state, label) in [
      (VideoTileHealth.paused, 'Paused'),
      (VideoTileHealth.stalled, 'Reconnecting video'),
      (VideoTileHealth.stopped, 'Video stopped'),
    ]) {
      health.value = {'camera:bob': state};
      await tester.pump();
      expect(find.text(label), findsOneWidget, reason: '$state');
      expect(find.byKey(const Key('video')), findsOneWidget);
    }
    health.value = const {};
    await tester.pump();
    expect(find.text('Video stopped'), findsNothing);
  });

  testWidgets('another tile\'s state does not label this one', (tester) async {
    await pump(tester);
    health.value = {'screen:bob': VideoTileHealth.stalled};
    await tester.pump();
    expect(find.text('Reconnecting video'), findsNothing);
  });
}
