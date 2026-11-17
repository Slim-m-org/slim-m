// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Joining a call asked pactl for the same device list three times in one
/// instant and started two `pactl subscribe` processes; each spawn forks the
/// app on its UI thread.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/pactl_sharing.dart';

class _GatedPactl {
  final calls = <List<String>>[];
  final _pending = <Completer<ProcessResult>>[];

  Future<ProcessResult> call(List<String> args) {
    calls.add(args);
    final done = Completer<ProcessResult>();
    _pending.add(done);
    return done.future;
  }

  void finishAll() {
    for (final done in _pending) {
      done.complete(ProcessResult(0, 0, '[]', ''));
    }
    _pending.clear();
  }
}

const _sources = ['-f', 'json', 'list', 'sources'];
const _sinkInputs = ['-f', 'json', 'list', 'sink-inputs'];

void main() {
  test('a device list asked three times at once spawns one pactl', () async {
    final pactl = _GatedPactl();
    final run = sharingDeviceQueries(pactl.call);

    final asks = [run(_sources), run(_sources), run(_sources)];
    pactl.finishAll();
    final answers = await Future.wait(asks);

    expect(pactl.calls, [_sources]);
    expect(answers.map((a) => a.stdout), ['[]', '[]', '[]']);
  });

  test('a device list asked after the last one ended asks again', () async {
    final pactl = _GatedPactl();
    final run = sharingDeviceQueries(pactl.call);

    final first = run(['get-default-source']);
    pactl.finishAll();
    await first;
    final second = run(['get-default-source']);
    pactl.finishAll();
    await second;

    expect(pactl.calls, [
      ['get-default-source'],
      ['get-default-source'],
    ]);
  });

  test('stream lists and moves always run their own pactl', () async {
    final pactl = _GatedPactl();
    final run = sharingDeviceQueries(pactl.call);

    final asks = [
      run(_sinkInputs),
      run(_sinkInputs),
      run(['move-sink-input', '7', 'sink_b']),
      run(['move-sink-input', '7', 'sink_b']),
    ];
    pactl.finishAll();
    await Future.wait(asks);

    expect(pactl.calls, hasLength(4));
  });

  test('one pactl subscribe serves every listener while any listens', () async {
    var started = 0;
    var cancelled = 0;
    late StreamController<String> upstream;
    final shared = sharedWhileListened(() {
      started++;
      upstream = StreamController<String>(onCancel: () => cancelled++);
      return upstream.stream;
    });

    final seenA = <String>[];
    final seenB = <String>[];
    final a = shared().listen(seenA.add);
    final b = shared().listen(seenB.add);
    upstream.add("Event 'new' on sink #4");
    await pumpEventQueue();

    expect(started, 1);
    expect(seenA, ["Event 'new' on sink #4"]);
    expect(seenB, ["Event 'new' on sink #4"]);

    await a.cancel();
    expect(cancelled, 0);
    await b.cancel();
    await pumpEventQueue();
    expect(cancelled, 1);

    final c = shared().listen((_) {});
    expect(started, 2);
    await c.cancel();
  });
}
