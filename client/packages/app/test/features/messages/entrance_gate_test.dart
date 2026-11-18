// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which newest row counts as an arrival: decided by where it sits in arrival
/// order, so a row a delete, discard or landing exposes never rises in again.
library;

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/message_entrance.dart';
import 'package:slimm_app/src/features/messages/widgets/transcript_items.dart';
import 'package:slimm_data/data.dart';

TranscriptItem _stored(String id, {required int seq, int createdAt = 0}) =>
    StoredItem(
      Message(
        id: id,
        channelId: 'c1',
        seq: seq,
        content: id,
        createdAt: createdAt,
        pending: seq == 0,
        failed: false,
      ),
    );

TranscriptItem _private(String id, int createdAt) => PrivateItem(
  api.EphemeralMessage(
    id: id,
    channelId: 'c1',
    authorId: 'bot',
    authorDisplayName: 'Bot',
    content: id,
    inReplyToId: 'm1',
    createdAt: createdAt,
  ),
);

/// Each admit a quiet stretch after the last, so only arrival order decides.
List<bool> _admitAll(List<List<TranscriptItem>> builds) {
  final gate = EntranceGate();
  var now = DateTime(2026, 11, 18);
  return [
    for (final items in builds)
      withClock(Clock.fixed(now = now.add(const Duration(seconds: 5))), () {
        return gate.admit(items, atLatest: true);
      }),
  ];
}

void main() {
  final m1 = _stored('m1', seq: 1);
  final m2 = _stored('m2', seq: 2);
  final m3 = _stored('m3', seq: 3);

  test('the first build and a new newest message', () {
    expect(
      _admitAll([
        [m1, m2],
        [m1, m2, m3],
      ]),
      [false, true],
    );
  });

  test('deleting the newest exposes an older row, which stays put', () {
    expect(
      _admitAll([
        [m1, m2],
        [m1, m2, m3],
        [m1, m2],
        [m1],
      ]),
      [false, true, false, false],
    );
  });

  test('a send rises in once, not again when it lands with its seq', () {
    final pending = _stored('p1', seq: 0, createdAt: 100);
    final landed = _stored('p1', seq: 3, createdAt: 100);
    expect(
      _admitAll([
        [m1, m2],
        [m1, m2, pending],
        [m1, m2, landed],
      ]),
      [false, true, false],
    );
  });

  test('discarding a failed send exposes a message delivered under it', () {
    final pending = _stored('p1', seq: 0, createdAt: 100);
    expect(
      _admitAll([
        [m1, pending],
        [m1, m2, pending],
        [m1, m2],
      ]),
      [false, false, false],
    );
  });

  test('a private answer arriving last rises in; dismissing it does not '
      'replay the one above', () {
    expect(
      _admitAll([
        [m1, m2],
        [m1, m2, _private('e1', 50)],
        [m1, m2],
      ]),
      [false, true, false],
    );
  });
}
