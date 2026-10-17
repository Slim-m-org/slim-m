// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A gap of a minute starts a fresh block rather than extending the last one.
///
/// Messages from one author used to keep joining the same block for minutes,
/// so a slow conversation rendered as a wall of text with the author's
/// picture and name only at the very top. Reported 2026-08-13, alongside a
/// screenshot of what the other client does instead.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript_dividers.dart';
import 'package:slimm_data/data.dart';

Message _at(int minute, {String author = 'ada'}) => Message(
  id: 'm$minute-$author',
  channelId: 'c1',
  authorId: author,
  authorDisplayName: author,
  seq: minute,
  content: 'hello',
  createdAt: Duration(minutes: minute).inMilliseconds,
  pending: false,
  failed: false,
);

void main() {
  test('a minute apart is a new block, seconds apart is not', () {
    expect(
      isGrouped(_at(1), _at(0)),
      isFalse,
      reason:
          'a full minute of silence is long enough that the next line wants '
          'its author named again',
    );

    final burst = Message(
      id: 'burst',
      channelId: 'c1',
      authorId: 'ada',
      authorDisplayName: 'ada',
      seq: 2,
      content: 'and another thing',
      createdAt: const Duration(seconds: 20).inMilliseconds,
      pending: false,
      failed: false,
    );
    expect(
      isGrouped(burst, _at(0)),
      isTrue,
      reason:
          'somebody typing three lines in a row is one thought, and heading '
          'each of them separately is noisier than the wall it replaced',
    );
  });

  test('a different author always starts a new block', () {
    expect(isGrouped(_at(0, author: 'grace'), _at(0)), isFalse);
  });
}
