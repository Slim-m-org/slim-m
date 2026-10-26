// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call's own playout must stay out of the Linux share audio mix, with no rerouting of anything.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/share_audio_graph.dart';
import 'package:slimm_rtc/src/share_audio_graph_parse.dart';

const _ownPid = 4242;

/// A just-enough PipeWire: playback streams with ports, one mix node, and the links made into it.
class _FakeGraph implements ShareAudioGraph {
  bool canDrive = true;
  bool mix = false;
  String? exported = 'unset';
  int destroys = 0;
  final links = <(int, int)>[];
  final streams = <int, String>{20: '$_ownPid', 30: '999'};

  @override
  bool get supported => canDrive;
  @override
  int get processId => _ownPid;

  @override
  Future<bool> createMix(String name) async => mix = true;

  @override
  Future<bool> link(int out, int input) async {
    links.add((out, input));
    return true;
  }

  @override
  void exportCaptureSource(String? source) => exported = source;

  @override
  Future<void> destroy() async {
    destroys++;
    mix = false;
    links.clear();
  }

  @override
  Future<String?> dump() async => jsonEncode([
        for (final e in streams.entries) ...[
          _node(e.key, 'Stream/Output/Audio', e.value),
          _port(e.key * 10 + 1, e.key, 'out', 'FL'),
          _port(e.key * 10 + 2, e.key, 'out', 'FR'),
        ],
        if (mix) ...[
          {
            'id': 90,
            'info': {
              'props': {'node.name': 'slimm-share-mix'}
            }
          },
          _port(91, 90, 'in', 'FL'),
          _port(92, 90, 'in', 'FR'),
        ],
        for (final l in links)
          {
            'id': 500 + l.$1,
            'info': {
              'props': {'link.input.node': 90, 'link.output.port': l.$1}
            }
          },
      ]);

  Map<String, dynamic> _node(int id, String cls, String pid) => {
        'id': id,
        'info': {
          'props': {
            'media.class': cls,
            'application.process.id': int.parse(pid),
          }
        }
      };

  Map<String, dynamic> _port(int id, int node, String dir, String ch) => {
        'id': id,
        'info': {
          'props': {'node.id': node, 'port.direction': dir, 'audio.channel': ch}
        }
      };
}

void main() {
  late _FakeGraph graph;
  late ShareAudioIsolation isolation;

  setUp(() {
    graph = _FakeGraph();
    isolation = ShareAudioIsolation(
      graph: graph,
      followEvery: const Duration(milliseconds: 20),
    );
  });
  tearDown(() => isolation.end());

  test('another app is linked into the mix, channel for channel', () async {
    expect(await isolation.begin(), isTrue);
    expect(graph.links.toSet(), {(301, 91), (302, 92)});
  });

  test('this process\'s own playout is never linked in', () async {
    await isolation.begin();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(graph.links.where((l) => l.$1 ~/ 10 == 20), isEmpty);
  });

  test('an app that starts mid-share is picked up, once', () async {
    await isolation.begin();
    graph.streams[40] = '1000';
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(graph.links.where((l) => l.$1 ~/ 10 == 40), hasLength(2));
  });

  test('the capture is pointed at the mix and released at the end', () async {
    await isolation.begin();
    expect(graph.exported, shareMixSource);
    await isolation.end();
    expect(graph.exported, isNull);
    expect(graph.destroys, 1);
    expect(isolation.active, isFalse);
  });

  test('ending twice tears down once', () async {
    await isolation.begin();
    await isolation.end();
    await isolation.end();
    expect(graph.destroys, 1);
  });

  test('with no sound server to drive it changes nothing', () async {
    graph.canDrive = false;
    expect(await isolation.begin(), isFalse);
    expect(graph.exported, 'unset');
    expect(isolation.active, isFalse);
  });

  test('a share that fails to start ends the isolation', () async {
    final control = ScreenShareControl(_NoBroadcast(), isolation: isolation);
    await control.setEnabled(
      true,
      quality: ScreenShareQuality.standard,
      includeAudio: true,
      publish: (_, __, ___) async => throw StateError('refused'),
      isSharing: () => false,
      onSettled: (_) {},
    );
    expect(isolation.active, isFalse);
    expect(graph.mix, isFalse);
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
    expect(graph.mix, isFalse);
    expect(graph.exported, 'unset');
  });

  test('a dump that is not a graph yields nothing to link', () {
    expect(foreignPlayback('not json', 1), isEmpty);
    expect(nodeIdNamed('{}', 'x'), isNull);
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
