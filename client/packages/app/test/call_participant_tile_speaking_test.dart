// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

VoiceParticipant _who({required bool speaking, required bool camera}) =>
    VoiceParticipant(
      identity: 'a',
      name: 'Alice',
      isSpeaking: speaking,
      isMuted: false,
      isLocal: false,
      isScreenSharing: false,
      isCameraOn: camera,
    );

Future<Border?> _border(WidgetTester tester, VoiceParticipant p) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: CallParticipantTile(
            participant: p,
            cameraView: p.isCameraOn
                ? const ColoredBox(color: Colors.teal)
                : null,
          ),
        ),
      ),
    ),
  );
  final box = tester
      .widgetList<DecoratedBox>(find.byType(DecoratedBox))
      .map((d) => d.decoration)
      .whereType<BoxDecoration>()
      .firstWhere((d) => d.border != null && d.borderRadius != null);
  return box.border as Border?;
}

void main() {
  testWidgets('a speaking camera tile carries the accent ring itself', (
    tester,
  ) async {
    final border = await _border(tester, _who(speaking: true, camera: true));
    expect(border!.top.color, AppTokens.dark.accent);
    expect(border.top.width, 2);
  });

  testWidgets('a quiet camera tile keeps the subtle border', (tester) async {
    final border = await _border(tester, _who(speaking: false, camera: true));
    expect(border!.top.color, AppTokens.dark.borderSubtle);
  });
}
