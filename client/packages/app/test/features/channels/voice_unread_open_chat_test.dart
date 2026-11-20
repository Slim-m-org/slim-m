// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner: "I can't clear a notification easily or read a chat on mobile/desktop of a voice chat without joining the voice channel".
/// The home's "Waiting for you" card and the inbox open a voice channel's chat without joining, as its row menu does.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_app/src/features/messages/widgets/inbox_sheet.dart';

import 'voice_unread_harness.dart';

void main() {
  testWidgets('the home card opens a voice chat without joining', (
    tester,
  ) async {
    final s = await pumpVoiceShell(tester, 1280, VoiceWaiting.heldMention);
    final card = find.widgetWithText(AppCard, 'WAITING FOR YOU');
    await tester.tap(
      await shownWhenReady(
        tester,
        find.descendant(of: card, matching: find.text('#movie-room')),
      ),
    );
    await expectReadingWithoutJoining(tester, s);
  });

  for (final (width, why) in [
    (390.0, VoiceWaiting.everyMessage),
    (1280.0, VoiceWaiting.everyMessage),
    (390.0, VoiceWaiting.mentionNotHeld),
  ]) {
    testWidgets('the inbox opens a voice chat without joining, '
        '${why.name} at $width', (tester) async {
      final semantics = tester.ensureSemantics();
      final s = await pumpVoiceShell(tester, width, why);
      await openInbox(tester);
      await tester.tap(
        await shownWhenReady(
          tester,
          find.descendant(
            of: find.byKey(inboxBodyBoxKey),
            matching: find.text('#movie-room'),
          ),
        ),
      );
      semantics.dispose();
      await expectReadingWithoutJoining(tester, s);
    });
  }
}
