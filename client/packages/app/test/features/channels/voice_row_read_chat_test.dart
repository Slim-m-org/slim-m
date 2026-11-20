// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner (2026-11-19): "that dot is related to voice call chats making dots saying i have an
/// unread message but i have no way of reading that message without joining the call and opening
/// that chat". A voice row's unread mark is a button that opens the chat without joining, at
/// phone and desktop width, and reading the chat there clears the mark.
library;

import 'package:flutter_test/flutter_test.dart';

import '../settings/home_shell_harness.dart';
import '../../support/async_wait.dart';
import 'voice_unread_harness.dart';

const _mark = 'Read the chat in movie-room, you were mentioned';

Future<int> _lastReadSeq(VoiceShell s) async {
  final row = await (s.db.select(
    s.db.channels,
  )..where((c) => c.id.equals(voiceId))).getSingle();
  return row.lastReadSeq;
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('the unread mark on a voice row opens its chat without '
        'joining, and reading it clears the mark, at $width', (tester) async {
      final semantics = tester.ensureSemantics();
      final s = await pumpVoiceShell(tester, width, VoiceWaiting.heldMention);
      await tester.tap(
        await shownWhenReady(tester, find.bySemanticsLabel(_mark)),
      );
      await expectReadsWithoutJoining(tester, s);

      var read = 0;
      for (var i = 0; i < 50 && read < 1; i++) {
        await pumpFrames(tester, frames: 2);
        read = (await tester.runAsync(() => _lastReadSeq(s)))!;
      }
      expect(read, 1, reason: 'the chat on screen was read');
      await pumpFrames(tester);
      expect(find.bySemanticsLabel(_mark), findsNothing);
      semantics.dispose();
      await teardown(tester, s.container, s.db);
    });
  }
}
