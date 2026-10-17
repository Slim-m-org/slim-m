// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tile's name keeps its "(you)" at the narrowest width a shared screen
/// squeezes the filmstrip to, and the state badge does not sit on the name.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';

VoiceParticipant _me(String name, {bool sharing = false}) => VoiceParticipant(
  identity: 'user-me',
  name: name,
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: sharing,
);

Future<void> _pump(WidgetTester tester, VoiceParticipant who) =>
    tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: CallParticipantTile(
                participant: who,
                width: kCallTileMinWidth,
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  setUpAll(loadRealFonts);

  testWidgets('the narrowest tile still reads Alice (you) in full', (
    tester,
  ) async {
    await _pump(tester, _me('Alice', sharing: true));

    for (final text in ['Alice', ' (you)']) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
      expect(paragraph.didExceedMaxLines, isFalse, reason: '"$text" truncated');
    }
  });

  testWidgets('a long name is cut before its (you)', (tester) async {
    await _pump(tester, _me('Charlotte Featherstonehaugh'));

    final you = tester.renderObject<RenderParagraph>(find.text(' (you)'));
    expect(you.didExceedMaxLines, isFalse);
    final name = tester.renderObject<RenderParagraph>(
      find.text('Charlotte Featherstonehaugh'),
    );
    expect(name.didExceedMaxLines, isTrue);
  });

  testWidgets('the state badge sits clear of the name', (tester) async {
    await _pump(tester, _me('Alice', sharing: true));

    final name = tester
        .getRect(find.text('Alice'))
        .expandToInclude(tester.getRect(find.text(' (you)')));
    final badge = tester.getRect(find.byIcon(AppIcons.screenShare));
    expect(name.overlaps(badge), isFalse);
  });
}
