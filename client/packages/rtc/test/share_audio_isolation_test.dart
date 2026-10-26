// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call's own playout must stay out of the Linux share audio mix.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

const _ownPid = 4242;

/// A just-enough sound server: sinks, the streams playing on them, loaded modules and the default sink.
class _FakeServer {
  final sinks = <String, int>{'speakers': 1};
  String defaultSink = 'speakers';
  final modules = <String, String>{};
  final inputs = <int, ({int sink, String pid})>{
    10: (sink: 1, pid: '$_ownPid'),
    11: (sink: 1, pid: '999'),
    13: (sink: 1, pid: '700'),
    14: (sink: 1, pid: '701'),
  };
  var _nextModule = 50;
  final log = <String>[];

  Future<ProcessResult> run(List<String> args) async {
    log.add(args.join(' '));
    String out = '';
    switch (args) {
      case ['get-default-sink']:
        out = defaultSink;
      case ['set-default-sink', final name]:
        defaultSink = name;
      case ['list', 'short', 'modules']:
        out = modules.entries.map((e) => '${e.key}\t${e.value}').join('\n');
      case ['load-module', final name, ...final rest]:
        final id = '${_nextModule++}';
        modules[id] = '$name\t${rest.join(' ')}';
        for (final arg in rest) {
          if (arg.startsWith('sink_name=')) {
            sinks[arg.substring(10)] = sinks.length + 1;
          }
        }
        out = id;
      case ['unload-module', final id]:
        final line = modules.remove(id);
        final sink = RegExp(r'sink_name=(\S+)').firstMatch(line ?? '');
        if (sink != null) sinks.remove(sink.group(1));
      case ['-f', 'json', 'list', 'sinks']:
        out = jsonEncode([
          for (final e in sinks.entries) {'index': e.value, 'name': e.key},
        ]);
      case ['-f', 'json', 'list', 'sink-inputs']:
        out = jsonEncode([
          for (final e in inputs.entries)
            {
              'index': e.key,
              'sink': e.value.sink,
              'properties': {
                'application.process.id': e.value.pid,
                if (e.key == 13) 'media.name': 'loopback-7 output',
                if (e.key == 14) 'target.object': 'speakers',
              },
            },
        ]);
      case ['move-sink-input', final id, final name]:
        inputs[int.parse(id)] = (
          sink: sinks[name]!,
          pid: inputs[int.parse(id)]!.pid,
        );
    }
    return ProcessResult(0, 0, out, '');
  }

  String sinkOf(int input) =>
      sinks.entries.firstWhere((e) => e.value == inputs[input]!.sink).key;
}

void main() {
  late _FakeServer server;
  late ShareAudioIsolation isolation;

  setUp(() {
    server = _FakeServer();
    isolation = ShareAudioIsolation(
      pulse: PulseAudio(run: server.run, processId: _ownPid),
      repinEvery: const Duration(milliseconds: 20),
    );
  });
  tearDown(() => isolation.end());

  test('the default sink becomes a mix that is looped to the real output',
      () async {
    expect(await isolation.begin(), isTrue);
    expect(server.defaultSink, 'slimm_share_mix');
    final loopback = server.modules.values.singleWhere(
      (m) => m.startsWith('module-loopback'),
    );
    expect(loopback, contains('source=slimm_share_mix.monitor'));
    expect(loopback, contains('sink=speakers'));
  });

  test('another app joins the mix while the call stays on the real output',
      () async {
    await isolation.begin();
    expect(server.sinkOf(11), 'slimm_share_mix');
    expect(server.sinkOf(10), 'speakers');
  });

  test(
      'the mix loopback output and a device-pinned app stay on the real output',
      () async {
    await isolation.begin();
    expect(server.sinkOf(13), 'speakers');
    expect(server.sinkOf(14), 'speakers');
  });

  test('a call stream that appears later is kept out of the mix', () async {
    await isolation.begin();
    server.inputs[12] =
        (sink: server.sinks['slimm_share_mix']!, pid: '$_ownPid');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(server.sinkOf(12), 'speakers');
  });

  test('ending restores the default sink and removes the modules', () async {
    await isolation.begin();
    await isolation.end();
    expect(server.defaultSink, 'speakers');
    expect(server.modules, isEmpty);
    expect(isolation.active, isFalse);
  });

  test('a mix left by a crash is removed before a new one is made', () async {
    server.modules['7'] = 'module-null-sink\tsink_name=slimm_share_mix';
    await isolation.begin();
    expect(server.modules.containsKey('7'), isFalse);
    expect(
      server.modules.values.where((m) => m.startsWith('module-null-sink')),
      hasLength(1),
    );
  });

  test('with no sound server to drive it changes nothing', () async {
    final silent = ShareAudioIsolation(
      pulse: PulseAudio(
        run: (_) async => ProcessResult(0, 1, '', 'no server'),
        processId: _ownPid,
      ),
    );
    expect(await silent.begin(), isFalse);
    expect(silent.active, isFalse);
  });

  test('a share that fails to start ends the isolation', () async {
    final control = ScreenShareControl(
      _NoBroadcast(),
      isolation: isolation,
    );
    await control.setEnabled(
      true,
      quality: ScreenShareQuality.standard,
      includeAudio: true,
      publish: (_, __, ___) async => throw StateError('refused'),
      isSharing: () => false,
      onSettled: (_) {},
    );
    expect(server.defaultSink, 'speakers');
    expect(server.modules, isEmpty);
  });

  test('a share with audio isolates it, and stopping ends it', () async {
    final control = ScreenShareControl(_NoBroadcast(), isolation: isolation);
    var activeWhilePublishing = false;
    await control.setEnabled(
      true,
      quality: ScreenShareQuality.standard,
      includeAudio: true,
      publish: (enabled, __, ___) async =>
          activeWhilePublishing = isolation.active,
      isSharing: () => true,
      onSettled: (_) {},
    );
    expect(activeWhilePublishing, isTrue);
    await control.setEnabled(
      false,
      quality: ScreenShareQuality.standard,
      publish: (_, __, ___) async {},
      isSharing: () => false,
      onSettled: (_) {},
    );
    expect(isolation.active, isFalse);
    expect(server.defaultSink, 'speakers');
  });

  test('a share without audio leaves the sound server alone', () async {
    final control = ScreenShareControl(_NoBroadcast(), isolation: isolation);
    await control.setEnabled(
      true,
      quality: ScreenShareQuality.standard,
      publish: (_, __, ___) async {},
      isSharing: () => true,
      onSettled: (_) {},
    );
    expect(server.log, isEmpty);
  });
}

class _NoBroadcast implements BroadcastBridge {
  @override
  bool get usesBroadcastExtension => false;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<void> requestStop() async {}
  @override
  set autoPublishEnabled(bool enabled) {}
  @override
  Stream<bool> get broadcastingChanges => const Stream.empty();
}
