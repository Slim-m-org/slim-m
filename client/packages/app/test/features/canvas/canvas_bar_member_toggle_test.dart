// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member list docks beside the canvas, so the canvas bar carries the
/// same toggle the channel header does; without it the list could not be
/// closed while the canvas is open.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_bar.dart';
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_design_system/design_system.dart';

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required double width,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      channelByIdProvider('c1').overrideWith((ref) => Stream.value(null)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(body: CanvasBar(channelId: 'c1')),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  testWidgets('a wide window shows the member toggle, and it closes and '
      'reopens the list', (tester) async {
    final container = await _pump(tester, width: 1600);
    expect(find.bySemanticsLabel('Toggle member list'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Toggle member list'));
    await tester.pump();
    expect(container.read(memberPaneVisibleProvider), isFalse);

    await tester.tap(find.bySemanticsLabel('Toggle member list'));
    await tester.pump();
    expect(container.read(memberPaneVisibleProvider), isTrue);
  });

  testWidgets('a window too narrow to dock the list has no toggle', (
    tester,
  ) async {
    await _pump(tester, width: 700);
    expect(find.bySemanticsLabel('Toggle member list'), findsNothing);
  });
}
