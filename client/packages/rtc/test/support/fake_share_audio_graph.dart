// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A just-enough PipeWire for driving [ShareAudioIsolation] without a sound server.
library;

import 'dart:async';
import 'dart:convert';

import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/share_audio_graph.dart';

/// The process id the fake graph reports as this app's own.
const fakeOwnPid = 4242;

/// Playback streams with ports, one mix node, and the links made into it.
class FakeShareAudioGraph implements ShareAudioGraph {
  bool canDrive = true;
  bool mixWorks = true;
  bool mix = false;
  String? exported = 'unset';
  int destroys = 0;
  final links = <(int, int)>[];
  final unlinked = <(int, int)>[];

  /// Every dump, link that took, unlink and destroy, in order.
  final calls = <String>[];

  /// What still fed the mix when it was removed; WirePlumber pauses the players behind these.
  List<(int, int)>? linkedAtDestroy;
  Completer<void>? holdLink;

  /// Holds every dump until completed, like a sound server that stopped answering.
  Completer<void>? holdDump;
  final streams = <int, String>{20: '$fakeOwnPid', 30: '999'};

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
  int get processId => fakeOwnPid;

  @override
  Future<bool> createMix(String name) async {
    creates++;
    await holdCreate?.future;
    return mix = mixWorks;
  }

  @override
  Future<bool> link(int out, int input) async {
    await holdLink?.future;
    calls.add('link $out $input');
    links.add((out, input));
    return true;
  }

  @override
  Future<bool> unlink(int out, int input) async {
    calls.add('unlink $out $input');
    unlinked.add((out, input));
    return links.remove((out, input));
  }

  @override
  void exportCaptureSource(String? source) => exported = source;

  @override
  Future<void> destroy() async {
    calls.add('destroy');
    destroys++;
    if (mix) linkedAtDestroy = [...links];
    mix = false;
    links.clear();
  }

  @override
  Future<String?> dump() async {
    calls.add('dump');
    await holdDump?.future;
    return jsonEncode([
      for (final e in streams.entries) ...[
        _node(e.key, 'Stream/Output/Audio', e.value),
        for (final (i, ch) in (channels[e.key] ?? const ['FL', 'FR']).indexed)
          _port(e.key * 10 + i + 1, e.key, 'out', ch),
      ],
      if (mix) ...[
        {
          'id': 90,
          'info': {
            'props': {'node.name': shareMixNode}
          }
        },
        _port(91, 90, 'in', 'FL'),
        _port(92, 90, 'in', 'FR'),
      ],
      for (final l in links)
        {
          'id': 500 + l.$1,
          'info': {
            'props': {
              'link.input.node': 90,
              'link.output.port': l.$1,
              'link.input.port': l.$2,
            }
          }
        },
    ]);
  }

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
