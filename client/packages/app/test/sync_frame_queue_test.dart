// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/sync_frame_queue.dart';

api.ServerEvent _event(int n) => api.ServerEvent.parse(
  '{"type":"read_state.changed","channel_id":"c$n","last_read_seq":$n}',
)!;

String _id(api.ServerEvent e) => (e as api.ReadStateChanged).channelId;

void main() {
  test(
    'a held queue applies nothing until flush, then in arrival order',
    () async {
      final seen = <String>[];
      final queue = SerialFrameQueue(
        (e) async => seen.add(_id(e)),
        onError: (_, _) {},
      );

      queue
        ..add(_event(1))
        ..add(_event(2));
      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty);

      await queue.flush();
      expect(seen, ['c1', 'c2']);
    },
  );

  test('frames arriving while flush drains join the same drain', () async {
    final seen = <String>[];
    late final SerialFrameQueue queue;
    queue = SerialFrameQueue((e) async {
      seen.add(_id(e));
      if (seen.length == 1) queue.add(_event(2));
      await Future<void>.delayed(Duration.zero);
    }, onError: (_, _) {});

    queue.add(_event(1));
    await queue.flush();
    queue.add(_event(3));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(seen, ['c1', 'c2', 'c3']);
  });

  test('once live, the next frame waits for the previous handler', () async {
    final gate = Completer<void>();
    final log = <String>[];
    final queue = SerialFrameQueue((e) async {
      log.add('start ${_id(e)}');
      if (_id(e) == 'c1') await gate.future;
      log.add('end ${_id(e)}');
    }, onError: (_, _) {});
    await queue.flush();

    queue
      ..add(_event(1))
      ..add(_event(2));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(log, ['start c1']);

    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(log, ['start c1', 'end c1', 'start c2', 'end c2']);
  });

  test(
    'a live handler failure is reported and the next frame still runs',
    () async {
      final seen = <String>[];
      final errors = <Object>[];
      final queue = SerialFrameQueue((e) async {
        if (_id(e) == 'c1') throw StateError('boom');
        seen.add(_id(e));
      }, onError: (error, _) => errors.add(error));
      await queue.flush();

      queue
        ..add(_event(1))
        ..add(_event(2));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(errors.single, isA<StateError>());
      expect(seen, ['c2']);
    },
  );

  test(
    'a failure while flushing is thrown to the connect draining it',
    () async {
      final queue = SerialFrameQueue(
        (e) async => throw StateError('boom'),
        onError: (_, _) {},
      );
      queue.add(_event(1));

      await expectLater(queue.flush(), throwsStateError);
    },
  );

  test('clear drops what is still waiting', () async {
    final seen = <String>[];
    final queue = SerialFrameQueue(
      (e) async => seen.add(_id(e)),
      onError: (_, _) {},
    );
    queue
      ..add(_event(1))
      ..clear();

    await queue.flush();
    expect(seen, isEmpty);
  });
}
