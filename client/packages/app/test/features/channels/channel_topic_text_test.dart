// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The header topic is one ellipsised line; hover and tap show all of it.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_topic_text.dart';
import 'package:slimm_design_system/design_system.dart';

const _topic =
    'General chat for the whole Space - keep it friendly, and keep call '
    'logistics in #main instead of here, and read the pinned rules first.';

Future<void> _pump(
  WidgetTester tester,
  double width, {
  String topic = _topic,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 200, child: ChannelTopicText(topic: topic)),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('hovering the truncated topic shows the full text', (
    tester,
  ) async {
    await _pump(tester, 1280);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(ChannelTopicText)));
    await tester.pump(const Duration(seconds: 2));

    expect(find.text(_topic), findsNWidgets(2));
  });

  testWidgets('tapping at 390 opens a sheet with the full text', (
    tester,
  ) async {
    await _pump(tester, 390);
    await tester.tap(find.byType(ChannelTopicText));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      _topic,
    );
  });

  testWidgets('tapping at 1280 opens the same text in a dialog', (
    tester,
  ) async {
    await _pump(tester, 1280);
    await tester.tap(find.byType(ChannelTopicText));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('a screen reader reads the whole topic as a button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, 390);

    expect(
      tester.getSemantics(find.byType(FocusableTapTarget)),
      matchesSemantics(
        label: _topic,
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('Tab reaches the topic and Enter opens it', (tester) async {
    await _pump(tester, 1280);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('blank space after a short topic is not part of the target', (
    tester,
  ) async {
    await _pump(tester, 1280, topic: 'Short');
    await tester.tapAt(const Offset(150, 8));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.text('Short'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('on touch there is no tooltip to fight the tap', (tester) async {
    await _pump(tester, 390);
    expect(find.byType(Tooltip), findsNothing);
  });
}
