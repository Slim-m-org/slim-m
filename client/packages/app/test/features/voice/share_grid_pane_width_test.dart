// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The share grid picks its columns from the pane it is laid out in, width and
/// height both. With the member pane docked a 1400 px window leaves the call a
/// pane of about 700 px, so a grid sized from the window made tiles of about
/// 150 px; and two shares in a wide pane once got a third of it each.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/share_stage_grid.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

VoiceParticipant _sharer(String id) => VoiceParticipant(
  identity: id,
  name: id,
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: true,
);

const _paneHeight = 760.0;

Finder _tile(String id) => find.byKey(ValueKey('share-tile-$id'));

Future<void> _pumpGrid(
  WidgetTester tester, {
  required double pane,
  required int shares,
}) async {
  tester.view.physicalSize = const Size(2400, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final harness = VoiceHarness();
  addTearDown(harness.dispose);
  final controller = harness.controllerWith(FakeSession(), voiceApi());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: pane,
              child: SingleChildScrollView(
                child: ShareGrid(
                  shares: [for (var i = 0; i < shares; i++) _sharer('s$i')],
                  controller: controller,
                  onStopWatching: (_) {},
                  onFocus: (_) {},
                  maxHeight: _paneHeight,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final (pane, shares, columns) in [
    (355.0, 2, 1),
    (355.0, 3, 1),
    (355.0, 4, 1),
    (700.0, 2, 1),
    (700.0, 3, 1),
    (700.0, 4, 2),
    (1400.0, 2, 2),
    (1400.0, 3, 2),
    (1400.0, 4, 2),
    (2400.0, 3, 3),
  ]) {
    testWidgets('$shares shares in a ${pane.toInt()} px pane make $columns '
        'column(s) of tiles that fit', (tester) async {
      await _pumpGrid(tester, pane: pane, shares: shares);

      final ids = [for (var i = 0; i < shares; i++) 's$i'];
      final firstRow = tester.getTopLeft(_tile('s0')).dy;
      final inFirstRow = ids.where(
        (id) => tester.getTopLeft(_tile(id)).dy == firstRow,
      );
      expect(inFirstRow.length, columns);
      final width = tester.getSize(_tile('s0')).width;
      expect(width * columns + (columns - 1) * 12, lessThanOrEqualTo(pane));
      final rows = (shares / columns).ceil();
      final height = tester.getSize(_tile('s0')).height;
      expect(rows * height + (rows - 1) * 12, lessThanOrEqualTo(_paneHeight));
      if (pane >= 700) expect(width, greaterThanOrEqualTo(300));
      expect(tester.takeException(), isNull);
    });
  }
}
