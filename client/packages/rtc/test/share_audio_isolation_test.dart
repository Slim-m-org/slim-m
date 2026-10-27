// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call's own playout must stay out of the Linux share audio mix, with no rerouting of anything.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/share_audio_graph.dart';
import 'package:slimm_rtc/src/share_audio_graph_parse.dart';

import 'support/session_fakes.dart';

const _ownPid = 4242;

/// A just-enough PipeWire: playback streams with ports, one mix node, and the links made into it.
class _FakeGraph implements ShareAudioGraph {
  bool canDrive = true;
  bool mix = false;
  String? exported = 'unset';
  int destroys = 0;
  final links = <(int, int)>[];
  final streams = <int, String>{20: '$_ownPid', 30: '999'};

  /// Output channels per stream; a stream not listed has FL and FR.
  final channels = <int, List<String>>{};
  final binaries = <int, String>{};
  Completer<void>? holdCreate;
  int creates = 0;
  @override
  String? executableName = 'slimm';

  @override
  bool get supported => canDrive;
  @override
  int get processId => _ownPid;

  @override
  Future<bool> createMix(String name) async {
    creates++;
    await holdCreate?.future;
    return mix = true;
  }

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
          for (final (i, ch) in (channels[e.key] ?? const ['FL', 'FR']).indexed)
            _port(e.key * 10 + i + 1, e.key, 'out', ch),
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
            'application.name': 'app$id',
            if (binaries[id] != null)
              'application.process.binary': binaries[id],
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

  test('a stop during start leaves no mix behind', () async {
    graph.holdCreate = Completer<void>();
    final started = isolation.begin();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final ended = isolation.end();
    graph.holdCreate!.complete();

    expect(await started, isFalse);
    await ended;
    expect(isolation.active, isFalse);
    expect(graph.mix, isFalse);
    expect(graph.exported, 'unset');
  });

  test('two starts at once make one mix', () async {
    final first = isolation.begin();
    final second = isolation.begin();

    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(graph.creates, 1);
  });

  test('a share that ends on its own ends the mix', () async {
    final control = ScreenShareControl(_NoBroadcast(), isolation: isolation);
    await isolation.begin();

    await control.shareEnded();

    expect(isolation.active, isFalse);
    expect(graph.mix, isFalse);
    expect(graph.exported, isNull);
  });

  test('a mono stream feeds both sides of the mix', () async {
    graph.channels[40] = ['MONO'];
    graph.streams[40] = '1000';
    await isolation.begin();
    expect(graph.links.where((l) => l.$1 ~/ 10 == 40).map((l) => l.$2).toSet(),
        {91, 92});
  });

  test('surround ports fold into their side and the sub is dropped', () async {
    graph.channels[40] = ['FL', 'FR', 'FC', 'LFE', 'RL', 'RR'];
    graph.streams[40] = '1000';
    await isolation.begin();
    final into = <int, List<int>>{};
    for (final l in graph.links.where((l) => l.$1 ~/ 10 == 40)) {
      (into[l.$1 % 10] ??= []).add(l.$2);
    }
    expect(into[3], unorderedEquals([91, 92]));
    expect(into[4], isNull);
    expect(into[5], [91]);
    expect(into[6], [92]);
  });

  test('a sandboxed own stream is excluded by its binary name', () async {
    graph.streams[50] = '7';
    graph.binaries[50] = 'slimm';
    await isolation.begin();
    expect(graph.links.where((l) => l.$1 ~/ 10 == 50), isEmpty);
    expect(graph.links.where((l) => l.$1 ~/ 10 == 30), isNotEmpty);
  });

  test('a stream naming no application is the server\'s plumbing', () {
    final dump = jsonEncode([
      {
        'id': 1,
        'info': {
          'props': {'media.class': 'Stream/Output/Audio'}
        }
      },
      {
        'id': 11,
        'info': {
          'props': {'node.id': 1, 'port.direction': 'out'}
        }
      },
    ]);
    expect(foreignPlayback(dump, 1), isEmpty);
  });

  _sessionTests();

  test('one built under a fake clock still ends in the real zone', () async {
    late ShareAudioIsolation built;
    fakeAsync((_) => built = ShareAudioIsolation(graph: _FakeGraph()));

    await built.end().timeout(const Duration(seconds: 2));
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

class _Unpublished extends Fake implements lk.LocalTrackPublication {
  _Unpublished(this.source);
  @override
  final lk.TrackSource source;
}

void _sessionTests() {
  Future<(VoiceSession, _FakeGraph, ShareAudioIsolation, lk.Room)> up() async {
    final graph = _FakeGraph();
    final isolation = ShareAudioIsolation(graph: graph);
    final room = ConnectlessRoom();
    final session = VoiceSession(
      roomFactory: () => room,
      shareAudioIsolation: isolation,
    );
    await session.join(url: 'wss://a.invalid', token: 't');
    await isolation.begin();
    return (session, graph, isolation, room);
  }

  Future<void> unpublish(lk.Room room, lk.TrackSource source) async {
    // ignore: invalid_use_of_internal_member, a room cannot be made to emit otherwise
    room.events.emit(
      lk.LocalTrackUnpublishedEvent(
        participant: _Local(),
        publication: _Unpublished(source),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  test('the share video going away outside the app ends the mix', () async {
    final (session, graph, isolation, room) = await up();
    addTearDown(session.dispose);

    await unpublish(room, lk.TrackSource.screenShareVideo);

    expect(isolation.active, isFalse);
    expect(graph.mix, isFalse);
  });

  test('another track going away leaves the mix alone', () async {
    final (session, graph, isolation, room) = await up();
    addTearDown(session.dispose);

    await unpublish(room, lk.TrackSource.microphone);

    expect(isolation.active, isTrue);
    expect(graph.mix, isTrue);
  });
}

class _Local extends Fake implements lk.LocalParticipant {}
