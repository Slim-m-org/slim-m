// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A wedged sound server must not hold up a join, a failed move is not a move,
/// and a sandboxed app still finds its own streams.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/pactl_sharing.dart';
import 'package:slimm_rtc/src/pulse_audio_io.dart';
import 'package:slimm_rtc/src/pulse_audio_parse.dart';

const _sources = ['-f', 'json', 'list', 'sources'];

String _streams(String pidValue, {String? binary}) => jsonEncode([
      {
        'index': 700,
        'source': 1,
        'properties': {
          'application.process.id': pidValue,
          if (binary != null) 'application.process.binary': binary,
        },
      },
    ]);

void main() {
  test('a pactl that never answers is killed and reported as a failure',
      () async {
    final started = <Process>[];
    final result = await runPactlWithin(
      _sources,
      within: const Duration(milliseconds: 100),
      start: (_, __) async {
        final process = await Process.start('sleep', ['30']);
        started.add(process);
        return process;
      },
    );

    expect(result.exitCode, isNot(0));
    expect(await started.single.exitCode, isNot(0));
  });

  test('a hung device query neither blocks nor is replayed to the next ask',
      () async {
    var calls = 0;
    final run = sharingDeviceQueries(
      (_) {
        calls++;
        return calls == 1
            ? Completer<ProcessResult>().future
            : Future.value(ProcessResult(0, 0, '[]', ''));
      },
      within: const Duration(milliseconds: 50),
    );

    final hung = await run(_sources);
    expect(hung.exitCode, isNot(0));
    final next = await run(_sources);

    expect(next.exitCode, 0);
    expect(calls, 2);
  });

  test('listing devices through a hung pactl answers null, not never',
      () async {
    final pulse = PulseAudio(
      run: sharingDeviceQueries(
        (_) => Completer<ProcessResult>().future,
        within: const Duration(milliseconds: 50),
      ),
    );

    expect(await pulse.sources().timeout(const Duration(seconds: 2)), isNull);
  });

  test('a move pactl refused is not reported as done', () async {
    Future<ProcessResult> pactl(List<String> args) async {
      if (args.first.startsWith('move-')) {
        return ProcessResult(0, 1, '', 'Failure: No such entity');
      }
      final out = args.contains('source-outputs') ? _streams('4242') : '[]';
      return ProcessResult(0, 0, out, '');
    }

    final pulse = PulseAudio(run: pactl, processId: 4242);

    expect(await pulse.moveOwnStreams(capture: true, deviceId: 'pulse:gone'),
        isFalse);
  });

  test('in a sandbox a stream is ours by binary, whatever pid it reports', () {
    final json = _streams('3', binary: 'slimm');

    expect(ownStreamIds(json, 4242, binary: 'slimm'), [700]);
    expect(ownStreamIds(json, 4242, binary: 'firefox'), isEmpty);
  });

  test('in a sandbox another app with the same pid number is not ours', () {
    final json = _streams('3', binary: 'firefox');

    expect(ownStreamIds(json, 3, binary: 'slimm'), isEmpty);
  });

  test('outside a sandbox the pid alone says whose stream it is', () {
    expect(ownStreamIds(_streams('4242', binary: 'other'), 4242), [700]);
    expect(ownStreamIds(_streams('3', binary: 'slimm'), 4242), isEmpty);
  });

  test('a pick moves the sandboxed stream the pid does not name', () async {
    final moves = <List<String>>[];
    Future<ProcessResult> pactl(List<String> args) async {
      if (args.first.startsWith('move-')) moves.add(args);
      final out = args.contains('source-outputs')
          ? _streams('3', binary: 'slimm')
          : '[]';
      return ProcessResult(0, 0, out, '');
    }

    final pulse = PulseAudio(run: pactl, processId: 4242, binary: 'slimm');

    expect(await pulse.moveOwnStreams(capture: true, deviceId: 'pulse:mic'),
        isTrue);
    expect(moves, [
      ['move-source-output', '700', 'mic'],
    ]);
  });
}
