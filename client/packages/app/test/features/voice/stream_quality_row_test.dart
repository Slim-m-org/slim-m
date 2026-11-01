// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_share_stage.dart';
import 'package:slimm_app/src/features/voice/widgets/stream_quality_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

CallStatsSampler _sampler(List<StatsEntry> Function() report) =>
    CallStatsSampler(
      remoteEvery: const Duration(seconds: 1),
      targets: () => [
        CallStatsTarget(
          identity: 'u2',
          name: 'Riley',
          source: CallStatsSource.screenShare,
          local: false,
          fetch: () async => report(),
        ),
      ],
    );

List<StatsEntry> _layer(int height, num fps) => [
  StatsEntry(
    type: 'inbound-rtp',
    id: 'in',
    values: {
      'kind': 'video',
      'frameWidth': height * 16 ~/ 9,
      'frameHeight': height,
      'framesPerSecond': fps,
    },
  ),
];

Widget _host(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.dark, AppTokens.dark),
  home: Scaffold(body: SizedBox(width: 260, child: child)),
);

void main() {
  testWidgets('reads Measuring, then the layer, then follows a switch', (
    tester,
  ) async {
    var report = _layer(1080, 60);
    final sampler = _sampler(() => report);
    addTearDown(sampler.dispose);
    await tester.pumpWidget(
      _host(
        StreamQualityRow(
          sampler: sampler,
          identity: 'u2',
          source: CallStatsSource.screenShare,
        ),
      ),
    );
    expect(find.text('Quality'), findsOneWidget);
    expect(find.text('Measuring'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('1080p 60'), findsOneWidget);

    report = _layer(360, 15);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('360p 15'), findsOneWidget);
    expect(find.text('1080p 60'), findsNothing);
  });

  testWidgets('stops sampling when the menu closes', (tester) async {
    final sampler = _sampler(() => _layer(720, 30));
    addTearDown(sampler.dispose);
    await tester.pumpWidget(
      _host(
        StreamQualityRow(
          sampler: sampler,
          identity: 'u2',
          source: CallStatsSource.screenShare,
        ),
      ),
    );
    expect(sampler.running, isTrue);
    await tester.pumpWidget(_host(const SizedBox()));
    expect(sampler.running, isFalse);
  });

  testWidgets('the stage context menu carries the row', (tester) async {
    final sampler = _sampler(() => _layer(720, 30));
    addTearDown(sampler.dispose);
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 260,
          height: 200,
          child: ScreenShareStage(
            sharerName: 'Riley',
            quality: StreamQualityRow(
              sampler: sampler,
              identity: 'u2',
              source: CallStatsSource.screenShare,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(ScreenShareStage), buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Quality'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('720p 30'), findsOneWidget);
  });
}
