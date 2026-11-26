// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The thread panel's rows against the channel's: the parent reads as a
/// message, replies carry no repeated quote, grouped rows keep one rhythm
/// around reaction chips, the mention band follows the channel, and a toolbar
/// label never lands on the row's own text.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras_model.dart';
import 'package:slimm_app/src/features/messages/widgets/message_hover_toolbar.dart';
import 'package:slimm_design_system/design_system.dart' show AppSpacing;
import 'package:slimm_data/data.dart' show Message;
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_identity.dart';
import 'package:slimm_app/src/features/messages/widgets/reply_quote.dart';

import 'message_hover_toolbar_support.dart';
import 'message_row_harness.dart';
import 'thread_panel_rig.dart';

const _chip = [
  api.ReactionSummary(emoji: '\u{203C}', count: 1, reacted: false),
];
const _chipKey = ValueKey('reaction-\u{203C}');

Finder _in(String id, Finder f) =>
    find.descendant(of: find.byKey(ValueKey(id)), matching: f);

void main() {
  for (final width in [390.0, 1280.0]) {
    group('at ${width.toInt()} wide', () {
      testWidgets('the parent has an avatar, a name and a time like a row', (
        tester,
      ) async {
        await pumpRig(tester, [rigMessage('r1', 1, 'nick')], width: width);
        final headers = find.byKey(MessageRowHeader.headerKey);
        expect(headers, findsNWidgets(2), reason: 'the parent and the reply');
        final parent = tester.getRect(headers.last);
        final reply = tester.getRect(_in('r1', headers));
        expect(parent.top, lessThan(reply.top));
        expect(parent.left, reply.left, reason: 'one gutter, one name column');
        expect(
          find.textContaining(RegExp(r'\d{1,2}:\d{2}[ap]$')),
          findsNWidgets(2),
          reason: 'the parent carries a sent time like the reply does',
        );
        final body = tester.getRect(
          find.byKey(const ValueKey('thread-parent-body')),
        );
        expect(body.top, greaterThanOrEqualTo(parent.bottom));
        await settleRig(tester);
      });

      testWidgets('a reply in a thread draws no quote, a channel reply does', (
        tester,
      ) async {
        final messages = [
          rigMessage('m1', 1, 'nick'),
          rigMessage('m2', 2, 'taka', replyTo: 'm1'),
        ];
        await pumpRig(tester, messages, width: width);
        expect(find.byKey(ReplyQuote.quoteKey), findsNothing);
        await settleRig(tester);
        await pumpRig(tester, messages, width: width, thread: false);
        expect(find.byKey(ReplyQuote.quoteKey), findsOneWidget);
        await settleRig(tester);
      });

      testWidgets(
        'chips sit flush under the body and the next row follows flush',
        (tester) async {
          await pumpRig(
            tester,
            [rigMessage('a1', 1, 'nick'), rigMessage('a2', 2, 'nick')],
            width: width,
            extras: {'a1': const MessageExtras(reactions: _chip)},
          );
          final text = tester.getRect(_in('a1', find.text('body a1')));
          final chip = tester.getRect(find.byKey(_chipKey));
          final next = tester.getRect(find.byKey(const ValueKey('a2')));
          expect(
            chip.top,
            text.bottom - AppSpacing.s4,
            reason: 'pulled up a step under the body (owner fix 302)',
          );
          expect(
            next.top,
            chip.bottom,
            reason: 'no phantom gap under the chips',
          );
          await settleRig(tester);
        },
      );

      testWidgets('thread rows keep the channel rhythm', (tester) async {
        final messages = [
          rigMessage('a1', 1, 'nick'),
          rigMessage('a2', 2, 'nick'),
          rigMessage('a3', 3, 'taka'),
        ];
        final extras = {'a1': const MessageExtras(reactions: _chip)};
        Future<List<double>> heights(bool thread) async {
          await pumpRig(
            tester,
            messages,
            width: width,
            thread: thread,
            extras: extras,
          );
          final out = [
            for (final id in ['a1', 'a2', 'a3'])
              tester.getSize(find.byKey(ValueKey(id))).height,
          ];
          await settleRig(tester);
          return out;
        }

        expect(await heights(true), await heights(false));
      });

      testWidgets(
        'consecutive replies from one author in a thread share one header',
        (tester) async {
          final replies = [
            rigMessage('m1', 1, 'nick'),
            rigMessage('r1', 2, 'taka', replyTo: 'm1'),
            rigMessage('r2', 3, 'taka', replyTo: 'm1'),
            rigMessage('r3', 4, 'taka', replyTo: 'm1'),
          ];
          final plain = [
            rigMessage('m1', 1, 'nick'),
            rigMessage('r1', 2, 'taka'),
            rigMessage('r2', 3, 'taka'),
            rigMessage('r3', 4, 'taka'),
          ];
          Future<(List<int>, List<double>)> measure(
            List<Message> messages,
            bool thread,
          ) async {
            await pumpRig(tester, messages, width: width, thread: thread);
            const ids = ['r1', 'r2', 'r3'];
            final result = (
              [
                for (final id in ids)
                  _in(
                    id,
                    find.byKey(MessageRowHeader.headerKey),
                  ).evaluate().length,
              ],
              [
                for (final id in ids)
                  tester.getSize(find.byKey(ValueKey(id))).height,
              ],
            );
            await settleRig(tester);
            return result;
          }

          final inThread = await measure(replies, true);
          expect(inThread.$1, [1, 0, 0], reason: 'one header for the run');
          expect(inThread.$2, (await measure(plain, true)).$2);
          expect((await measure(replies, false)).$1, [1, 1, 1]);
        },
      );

      testWidgets(
        'a bare reply to me wears no band in a thread, in a channel it does',
        (tester) async {
          final messages = [
            rigMessage('m1', 1, 'nick'),
            rigMessage('m2', 2, 'taka', replyTo: 'm1'),
          ];
          final extras = {'m2': const MessageExtras(mentionsMe: true)};
          Color? fill() =>
              (tester
                          .widget<AnimatedContainer>(
                            _in('m2', find.byKey(MessageRow.hoverFillKey)),
                          )
                          .decoration!
                      as BoxDecoration)
                  .color;
          await pumpRig(tester, messages, width: width, extras: extras);
          expect(fill(), Colors.transparent);
          await settleRig(tester);
          await pumpRig(
            tester,
            messages,
            width: width,
            thread: false,
            extras: extras,
          );
          expect(fill(), isNot(Colors.transparent));
          await settleRig(tester);
        },
      );

      testWidgets(
        'an explicit mention keeps its band in a thread, full row wide',
        (tester) async {
          await pumpRig(
            tester,
            [
              rigMessage('m1', 1, 'nick'),
              rigMessage('m2', 2, 'taka', replyTo: 'm1', content: '@nick look'),
            ],
            width: width,
            extras: {'m2': const MessageExtras(mentionsMe: true)},
          );
          final fill = _in('m2', find.byKey(MessageRow.hoverFillKey));
          final color =
              (tester.widget<AnimatedContainer>(fill).decoration!
                      as BoxDecoration)
                  .color;
          expect(color, isNot(Colors.transparent));
          expect(
            tester.getSize(fill).width,
            tester.getSize(find.byKey(const ValueKey('m2'))).width,
          );
          await settleRig(tester);
        },
      );
    });
  }

  testWidgets('a toolbar label opens above the plate, off the row text', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        Padding(
          padding: const EdgeInsets.only(top: 240),
          child: hoverRow(
            message(content: 'one line'),
            actions: hoverActions(canEdit: true),
          ),
        ),
      ),
    );
    final mouse = await hoverMouse(tester);
    await hoverHover(tester, mouse, find.byKey(const ValueKey('m1')));
    await mouse.moveTo(
      tester.getCenter(find.byKey(MessageHoverToolbar.editKey)),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final label = tester.getRect(find.text('Edit'));
    final plate = tester.getRect(hoverPlate);
    expect(label.bottom, lessThanOrEqualTo(plate.top));
  });
}
