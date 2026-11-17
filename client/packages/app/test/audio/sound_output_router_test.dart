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

void main() {
  test('moves this app\'s playing stream to the chosen sink once', () async {
    final server = _Server();
    await _router(server, 'pulse:sink_b').followChosenOutput();

    expect(server.moves, [
      ['move-sink-input', '7', 'sink_b'],
    ]);
  });

  test('a stream already on the chosen sink waits for the new one', () async {
    final moves = <List<String>>[];
    var listings = 0;
    Future<ProcessResult> run(List<String> args) async {
      if (args.first.startsWith('move-')) moves.add(args);
      final out = switch (args) {
        [..., 'sinks'] => [
          {'index': 1, 'name': 'sink_b'},
        ],
        [..., 'sink-inputs'] => [
          {
            'index': 7,
            'sink': 1,
            'properties': {'application.process.id': '$_pid'},
          },
          if (++listings > 1)
            {
              'index': 9,
              'sink': 0,
              'properties': {'application.process.id': '$_pid'},
            },
        ],
        _ => const <Object>[],
      };
      return ProcessResult(0, 0, jsonEncode(out), '');
    }

    final router = SoundOutputRouter(
      () => 'pulse:sink_b',
      pulse: PulseAudio(run: run, processId: _pid),
      supported: true,
      delays: const [Duration.zero, Duration(milliseconds: 1)],
    );
    await router.followChosenOutput();

    expect(moves, [
      ['move-sink-input', '9', 'sink_b'],
    ]);
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
