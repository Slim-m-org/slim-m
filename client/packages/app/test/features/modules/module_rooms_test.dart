// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The room state a slot renders from (decision 0131): read from the route,
/// kept current by `module.room` frames in `seq` order, and updated by the
/// person's own inputs.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/providers/module_rooms.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 4102444800000,
);

Map<String, dynamic> _room(int seq, String board) => {
  'module_id': 'noughts',
  'seq': seq,
  'state': {'board': board},
  'updated_at_ms': 1700000000000,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _Rig {
  _Rig(this.container, this.events, this.requests, this.sub);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final List<String> requests;
  final ProviderSubscription<ModuleRoomsModel> sub;

  ModuleRoomsModel get model => sub.read();

  ModuleRoomsController get controller =>
      container.read(moduleRoomsProvider('c1').notifier);
}

/// Channel `c1`'s rooms, served by [handler].
Future<_Rig> _rig(Future<http.Response> Function(http.Request) handler) async {
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final requests = <String>[];
  final container = ProviderContainer(
    overrides: [
      liveEventsProvider.overrideWithValue(events.stream),
      apiProvider.overrideWith((ref) {
        final client = testApi((request) {
          requests.add('${request.method} ${request.url.path} ${request.body}');
          return handler(request);
        }, session: api.SessionStore(tokens: _tokens));
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  final sub = container.listen(moduleRoomsProvider('c1'), (_, __) {});
  addTearDown(sub.close);
  await Future<void>.delayed(Duration.zero);
  return _Rig(container, events, requests, sub);
}

api.ModuleRoomChanged _frame(int seq, String? board, {String? ended}) =>
    api.ModuleRoomChanged(
      channelId: 'c1',
      moduleId: 'noughts',
      seq: seq,
      state: board == null ? null : {'board': board},
      ended: ended,
    );

Object? _board(_Rig rig) =>
    (rig.model.room('noughts')?.state as Map?)?['board'];

void main() {
  test(
    'a late joiner reads the board, then follows frames in seq order',
    () async {
      final rig = await _rig(
        (_) async => _json({
          'rooms': [_room(2, 'x...o....')],
        }),
      );
      expect(rig.requests, ['GET /channels/c1/module-rooms ']);
      expect(rig.model.room('noughts')!.seq, 2);
      expect(_board(rig), 'x...o....');

      rig.events.add(_frame(3, 'xx..o....'));
      await Future<void>.delayed(Duration.zero);
      expect(_board(rig), 'xx..o....');

      rig.events.add(_frame(2, 'x...o....'));
      await Future<void>.delayed(Duration.zero);
      expect(_board(rig), 'xx..o....', reason: 'an older frame is stale');

      rig.events.add(
        const api.ModuleRoomChanged(
          channelId: 'other',
          moduleId: 'noughts',
          seq: 9,
          state: {'board': 'ooo......'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(_board(rig), 'xx..o....', reason: 'another channel is not ours');

      rig.events.add(_frame(3, null, ended: 'call_ended'));
      await Future<void>.delayed(Duration.zero);
      expect(rig.model.room('noughts'), isNull);
    },
  );

  test('a read that left before a newer frame does not overwrite it', () async {
    final reply = Completer<void>();
    final rig = await _rig((_) async {
      await reply.future;
      return _json({
        'rooms': [_room(1, 'x........')],
      });
    });
    rig.events.add(_frame(2, 'x...o....'));
    await Future<void>.delayed(Duration.zero);
    reply.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(_board(rig), 'x...o....');
  });

  test('a read that a frame raced still brings the call scenes', () async {
    final reply = Completer<void>();
    final rig = await _rig((_) async {
      await reply.future;
      return _json({
        'rooms': [_room(1, 'x........')],
        'call_scenes': [
          {'module_id': 'noughts', 'title': 'Noughts'},
        ],
      });
    });
    rig.events.add(_frame(2, 'x...o....'));
    await Future<void>.delayed(Duration.zero);
    reply.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(_board(rig), 'x...o....');
    expect(rig.model.callScenes.map((s) => s.moduleId), ['noughts']);
  });

  test('a room that ended during a read stays gone', () async {
    final reply = Completer<void>();
    final rig = await _rig((_) async {
      await reply.future;
      return _json({
        'rooms': [_room(1, 'x........')],
      });
    });
    rig.events.add(_frame(2, null, ended: 'call_ended'));
    await Future<void>.delayed(Duration.zero);
    reply.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(rig.model.room('noughts'), isNull);
  });

  test('a failed read keeps the rooms and scenes already held', () async {
    var fail = false;
    final rig = await _rig((_) async {
      if (fail) return _json({'error': 'down'}, 503);
      return _json({
        'rooms': [_room(2, 'x...o....')],
        'call_scenes': [
          {'module_id': 'noughts', 'title': 'Noughts'},
        ],
      });
    });
    fail = true;
    await rig.controller.refresh();
    expect(_board(rig), 'x...o....');
    expect(rig.model.callScenes, hasLength(1));
  });

  test('a server without room state reads as no rooms', () async {
    final rig = await _rig((_) async => _json({'error': 'not found'}, 404));
    expect(rig.model.rooms, isEmpty);
  });

  test(
    'an input applies its answer and keeps a refusal for the sender',
    () async {
      var answer = <String, dynamic>{
        'applied': true,
        'seq': 1,
        'state': {'board': 'x........'},
      };
      final rig = await _rig((request) async {
        if (request.method == 'GET') return _json({'rooms': <Object>[]});
        return _json(answer);
      });
      final sent = rig.controller.send('noughts', '0');
      expect(rig.model.sending, {'noughts'});
      final result = await sent;
      expect(result!.applied, isTrue);
      expect(
        rig.requests.last,
        'POST /channels/c1/module-rooms/noughts/inputs {"input":"0"}',
      );
      expect(rig.model.sending, isEmpty);
      expect(_board(rig), 'x........');

      answer = {
        'applied': false,
        'seq': 1,
        'state': {'board': 'x........'},
        'reason': 'not your turn',
      };
      await rig.controller.send('noughts', '1');
      expect(rig.model.notices['noughts'], 'not your turn');
      expect(rig.model.room('noughts')!.seq, 1);

      answer = {'applied': true, 'seq': 0, 'state': null};
      await rig.controller.send('noughts', 'end');
      expect(rig.model.room('noughts'), isNull);
      expect(rig.model.notices, isEmpty);
    },
  );

  test(
    'a refused send keeps the server reason and the room as it was',
    () async {
      final rig = await _rig((request) async {
        if (request.method == 'GET') {
          return _json({
            'rooms': [_room(4, 'xo.......')],
          });
        }
        return _json({
          'error': 'only people taking part in this room can send it input',
        }, 403);
      });
      expect(await rig.controller.send('noughts', '2'), isNull);
      expect(
        rig.model.notices['noughts'],
        'only people taking part in this room can send it input',
      );
      expect(rig.model.room('noughts')!.seq, 4);
    },
  );
}
