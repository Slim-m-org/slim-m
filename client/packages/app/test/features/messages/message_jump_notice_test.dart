// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The small pure rules a jump's outcome is told through: what counts as
/// still looking, which refusal gets which sentence, and how far the
/// transcript window can be widened to reach a held message.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/features/messages/providers/message_jump.dart';
import 'package:slimm_app/src/features/messages/providers/retention_policy.dart';

void main() {
  test('only a jump into the same channel counts as seeking', () {
    const seeking = MessageJumpSeeking('c1', 'm1', 1);
    expect(jumpSeekingIn(seeking, 'c1'), isTrue);
    expect(jumpSeekingIn(seeking, 'c2'), isFalse);
    expect(jumpSeekingIn(const MessageJumpIdle(), 'c1'), isFalse);
    expect(
      jumpSeekingIn(const MessageJumpArrived('c1', 'm1', 1), 'c1'),
      isFalse,
    );
  });

  test('a missing message and a failed fetch are worded apart', () {
    final missing = jumpNoticeFor(
      const MessageJumpUnreachable('c1', 'm1', 3),
      'c1',
    );
    final failed = jumpNoticeFor(const MessageJumpFailed('c1', 'm1', 4), 'c1');

    expect(missing!.text, contains('Could not find that message'));
    expect(missing.retryable, isFalse);
    expect(missing.messageId, 'm1');
    expect(missing.token, 3);
    expect(failed!.text, contains('Could not load older messages'));
    expect(failed.retryable, isTrue);
  });

  test('a refusal in another channel, or none at all, has no notice', () {
    expect(
      jumpNoticeFor(const MessageJumpUnreachable('c2', 'm1', 1), 'c1'),
      isNull,
    );
    expect(
      jumpNoticeFor(const MessageJumpSeeking('c1', 'm1', 1), 'c1'),
      isNull,
    );
    expect(jumpNoticeFor(const MessageJumpIdle(), 'c1'), isNull);
  });

  test('the window widens to reach a held row, up to the ceiling', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final history = container.read(channelHistoryProvider('c1').notifier);
    final start = container.read(channelHistoryProvider('c1')).window;

    expect(history.widenWindowTo(start - 1), isTrue);
    expect(container.read(channelHistoryProvider('c1')).window, start);
    expect(history.widenWindowTo(start + 300), isTrue);
    expect(container.read(channelHistoryProvider('c1')).window, start + 300);
    expect(history.widenWindowTo(channelWindowCeiling), isTrue);
    expect(history.widenWindowTo(channelWindowCeiling + 1), isFalse);
    expect(
      container.read(channelHistoryProvider('c1')).window,
      channelWindowCeiling,
      reason: 'a row past the ceiling must not grow the window',
    );
  });
}
