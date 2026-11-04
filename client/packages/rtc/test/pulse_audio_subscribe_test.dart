// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `pactl subscribe` is never leaked by a cancel that races its start, and its death is logged.
@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show AppLog, LogLevel, LogRecord, LogSink;
import 'package:slimm_rtc/src/pulse_audio_io.dart';

class _Pactl extends Fake implements Process {
  final _out = StreamController<List<int>>();
  final _exit = Completer<int>();
  int kills = 0;

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    return true;
  }

  void die(int code) {
    _exit.complete(code);
    unawaited(_out.close());
  }
}

class _Records implements LogSink {
  final List<LogRecord> records = [];

  @override
  void write(LogRecord record) => records.add(record);
}

void main() {
  late _Records logs;

  setUp(() {
    logs = _Records();
    AppLog.install(logs);
    addTearDown(() => AppLog.install(null));
  });

  test('a cancel while the process is still starting kills it once it exists',
      () async {
    final pactl = _Pactl();
    final starting = Completer<Process>();
    final sub =
        subscribePactl(start: (_, __) => starting.future).listen((_) {});

    await sub.cancel();
    starting.complete(pactl);
    await pumpEventQueue();

    expect(pactl.kills, 1);
  });

  test('a cancel after the start kills the process', () async {
    final pactl = _Pactl();
    final sub = subscribePactl(start: (_, __) async => pactl).listen((_) {});
    await pumpEventQueue();

    await sub.cancel();

    expect(pactl.kills, 1);
  });

  test('pactl dying on its own is logged and ends the stream', () async {
    final pactl = _Pactl();
    final done = Completer<void>();
    subscribePactl(start: (_, __) async => pactl)
        .listen((_) {}, onDone: done.complete);
    await pumpEventQueue();

    pactl.die(3);
    await done.future;
    await pumpEventQueue();

    final exit = logs.records
        .where((r) => r.message.contains('pactl subscribe exited with code 3'));
    expect(exit.map((r) => r.level), [LogLevel.warning]);
  });

  test('lines are passed through', () async {
    final pactl = _Pactl();
    final seen = <String>[];
    final sub = subscribePactl(start: (_, __) async => pactl).listen(seen.add);
    await pumpEventQueue();

    pactl._out.add(utf8.encode("Event 'new' on sink #4\n"));
    await pumpEventQueue();

    expect(seen, ["Event 'new' on sink #4"]);
    await sub.cancel();
  });
}
