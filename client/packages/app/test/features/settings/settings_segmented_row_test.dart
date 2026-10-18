// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The segmented settings row and the notification banner's status styling.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/push_status.dart';
import 'package:slimm_app/src/features/settings/widgets/notification_status_banner.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_segmented_row.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
import 'package:slimm_design_system/design_system.dart';

Future<int?> _pump(WidgetTester tester, double width) async {
  int? picked;
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: SettingsSegmentedRow(
          label: 'Your camera',
          description: 'Sent to the call.',
          value: 1,
          choices: const [
            SettingsChoice(value: 0, label: '360p'),
            SettingsChoice(value: 1, label: '720p'),
            SettingsChoice(value: 2, label: '1080p'),
          ],
          onChanged: (i) => picked = i,
        ),
      ),
    ),
  );
  await tester.tap(find.text('1080p'));
  return picked;
}

void main() {
  testWidgets('a wide row puts the control beside the label', (tester) async {
    final picked = await _pump(tester, 900);
    expect(picked, 2);
    expect(
      tester.getTopRight(find.text('Your camera')).dy,
      lessThan(tester.getTopLeft(find.text('1080p')).dy + 20),
    );
    expect(
      tester.getTopLeft(find.text('360p')).dx,
      greaterThan(tester.getTopRight(find.text('Your camera')).dx),
    );
  });

  testWidgets('a narrow row drops the control under the label', (tester) async {
    await _pump(tester, 360);
    expect(
      tester.getTopLeft(find.text('360p')).dy,
      greaterThan(tester.getBottomLeft(find.text('Sent to the call.')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wide control stacks even in a pane a short one fits beside', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(496, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget row(List<String> labels) => SettingsSegmentedRow<int>(
      label: 'Noise suppression',
      value: 0,
      choices: [
        for (final (i, l) in labels.indexed) SettingsChoice(value: i, label: l),
      ],
      onChanged: (_) {},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Column(
            children: [
              row(const ['On', 'Off']),
              row(const ['Space default', 'Standard', 'Strong suppression']),
            ],
          ),
        ),
      ),
    );

    final labels = find.text('Noise suppression');
    expect(
      tester.getTopLeft(find.text('On')).dy,
      lessThan(tester.getBottomLeft(labels.first).dy),
      reason: 'two short segments leave the label room beside them',
    );
    expect(
      tester.getTopLeft(find.text('Space default')).dy,
      greaterThan(tester.getBottomLeft(labels.last).dy),
      reason: 'three long segments would leave the label too narrow',
    );
    expect(tester.takeException(), isNull);
  });

  test('only a problem reads as a warning banner', () {
    expect(notificationBannerStyle(PushStatus.registered).warn, isFalse);
    expect(
      notificationBannerStyle(PushStatus.unsupportedPlatform).warn,
      isTrue,
    );
  });
}
