// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A cursor that only moves must not rebuild the roster; only a person
/// arriving or leaving does.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_roster.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void _upsert(CanvasCursors cursors, double x) =>
    cursors.upsert(id: 'u1', x: x, y: 0, label: 'Una', colorIndex: 0);

void main() {
  testWidgets('a moving cursor schedules no frame, an arrival does', (
    tester,
  ) async {
    final cursors = CanvasCursors();
    addTearDown(cursors.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: CanvasPresenceRoster(
            callParticipants: const [],
            cursors: cursors,
          ),
        ),
      ),
    );

    _upsert(cursors, 1);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpAndSettle();

    _upsert(cursors, 2);
    _upsert(cursors, 3);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
