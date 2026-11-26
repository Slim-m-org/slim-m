// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// In a thread a reply to the viewer wears the mention band only when its text
/// names the viewer; an `@` for somebody else is not a ping.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras_model.dart';
import 'package:slimm_app/src/features/messages/providers/viewer_mention.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';

import 'thread_panel_rig.dart';

const _viewer = ViewerMentionTargets(username: 'Nick', roles: ['Mods']);

void main() {
  test('only a token that names the viewer pings them', () {
    for (final yes in [
      '@nick look',
      'hey @NICK',
      '(@everyone) read',
      '@here now',
      '@[mods] please',
    ]) {
      expect(contentMentionsViewer(yes, _viewer), isTrue, reason: yes);
    }
    for (final no in [
      '@taka thanks',
      'mail me at a@nick.dev',
      '@nicky no',
      '@[Admins] only',
      '@',
      'no mention',
    ]) {
      expect(contentMentionsViewer(no, _viewer), isFalse, reason: no);
    }
  });

  for (final (content, banded) in [
    ('@taka thanks', false),
    ('@nick thanks', true),
    ('@everyone thanks', true),
  ]) {
    testWidgets('a thread reply to me saying "$content" '
        '${banded ? 'wears' : 'wears no'} the band', (tester) async {
      await pumpRig(
        tester,
        [
          rigMessage('m1', 1, 'nick'),
          rigMessage('m2', 2, 'taka', replyTo: 'm1', content: content),
        ],
        extras: {'m2': const MessageExtras(mentionsMe: true)},
      );
      final fill = find.descendant(
        of: find.byKey(const ValueKey('m2')),
        matching: find.byKey(MessageRow.hoverFillKey),
      );
      final color =
          (tester.widget<AnimatedContainer>(fill).decoration! as BoxDecoration)
              .color;
      expect(color == Colors.transparent, !banded);
      await settleRig(tester);
    });
  }
}
