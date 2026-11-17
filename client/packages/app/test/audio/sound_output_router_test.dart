// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Interface sounds follow the speaker the call uses, where the platform has a
/// sound server to move a stream on.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/sound_output_router.dart';
import 'package:slimm_rtc/rtc.dart';

const _pid = 4242;

class _Server {
  final moves = <List<String>>[];

  Future<ProcessResult> run(List<String> args) async {
    if (args.contains('list')) {
      return ProcessResult(
        0,
        0,
        jsonEncode([
          {
            'index': 7,
            'properties': {'application.process.id': '$_pid'},
          },
          {
            'index': 8,
            'properties': {'application.process.id': '1'},
          },
        ]),
        '',
      );
    }
    moves.add(args);
    return ProcessResult(0, 0, '', '');
  }
}

SoundOutputRouter _router(
  _Server server,
  String? chosen, {
  bool supported = true,
}) => SoundOutputRouter(
  () => chosen,
  pulse: PulseAudio(run: server.run, processId: _pid),
  supported: supported,
  delays: const [Duration.zero, Duration(milliseconds: 1)],
);

/// A sound server whose own streams sit on a sink and show up from a given listing on.
class _SinkServer {
  /// Stream id to (sink index, the sink-input listing it first appears in).
  _SinkServer(Map<int, (int, int)> streams)
    : sinkOf = {for (final e in streams.entries) e.key: e.value.$1},
      _appears = {for (final e in streams.entries) e.key: e.value.$2};

  final Map<int, int> sinkOf;
  final Map<int, int> _appears;
  final moves = <List<String>>[];
  var _listings = 0;

  Future<ProcessResult> run(List<String> args) async {
    if (args.first.startsWith('move-')) {
      moves.add(args);
      sinkOf[int.parse(args[1])] = args[2] == 'sink_b' ? 1 : 0;
      return ProcessResult(0, 0, '', '');
    }
    final out = switch (args) {
      [..., 'sinks'] => [
        {'index': 0, 'name': 'sink_a'},
        {'index': 1, 'name': 'sink_b'},
      ],
      [..., 'sink-inputs'] => _streams(_listings++),
      _ => const <Object>[],
    };
    return ProcessResult(0, 0, jsonEncode(out), '');
  }

  List<Object> _streams(int listing) => [
    for (final id in sinkOf.keys)
      if (_appears[id]! <= listing)
        {
          'index': id,
          'sink': sinkOf[id],
          'properties': {'application.process.id': '$_pid'},
        },
  ];
}

SoundOutputRouter _routerOn(_SinkServer server) => SoundOutputRouter(
  () => 'pulse:sink_b',
  pulse: PulseAudio(run: server.run, processId: _pid),
  supported: true,
  delays: const [
    Duration.zero,
    Duration(milliseconds: 1),
    Duration(milliseconds: 2),
  ],
);

void main() {
  test('moves this app\'s playing stream to the chosen sink once', () async {
    final server = _SinkServer({7: (0, 0)});
    await _routerOn(server).followChosenOutput();

    expect(server.moves, [
      ['move-sink-input', '7', 'sink_b'],
    ]);
  });

  test('a stream already on the chosen sink waits for the new one', () async {
    final server = _SinkServer({7: (1, 0), 9: (0, 1)});
    await _routerOn(server).followChosenOutput();

    expect(server.moves, [
      ['move-sink-input', '9', 'sink_b'],
    ]);
  });

  test('the call\'s stream moving first does not stop the cue\'s from '
      'following', () async {
    final server = _SinkServer({7: (0, 0), 9: (0, 2)});
    await _routerOn(server).followChosenOutput();

    expect(server.moves, [
      ['move-sink-input', '7', 'sink_b'],
      ['move-sink-input', '9', 'sink_b'],
    ]);
    expect(server.sinkOf, {7: 1, 9: 1});
  });

  test('the system default moves nothing', () async {
    final server = _Server();
    await _router(server, null).followChosenOutput();
    expect(server.moves, isEmpty);
  });

  test('a platform without a sound server moves nothing and says so', () async {
    final server = _Server();
    final router = _router(server, 'pulse:sink_b', supported: false);
    await router.followChosenOutput();

    expect(server.moves, isEmpty);
    expect(router.testable, isFalse);
  });

  test('the test button is honest on the default output everywhere', () {
    expect(_router(_Server(), null, supported: false).testable, isTrue);
    expect(_router(_Server(), 'pulse:x', supported: true).testable, isTrue);
  });
}
