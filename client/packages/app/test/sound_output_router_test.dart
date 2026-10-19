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
  test('moves only this app\'s playing streams to the chosen sink', () async {
    final server = _Server();
    await _router(server, 'pulse:sink_b').followChosenOutput();

    expect(server.moves, [
      ['move-sink-input', '7', 'sink_b'],
      ['move-sink-input', '7', 'sink_b'],
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
