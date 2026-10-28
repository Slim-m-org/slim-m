// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading `pw-dump` output for the share mix; see `share_audio_isolation.dart`.
library;

import 'dart:convert';

/// The private sink the share capture records; also kept out of every device picker.
const shareMixNode = 'slimm-share-mix';

/// An app's playback stream and the output ports to link from.
typedef PlaybackStream = ({int nodeId, List<int> outPorts});

/// The share mix as it stands: its input ports and what already feeds it.
typedef MixState = ({List<int> inPorts, Set<int> linkedOutPorts});

List<Map<dynamic, dynamic>> _objects(String json) {
  try {
    final decoded = jsonDecode(json);
    return decoded is List
        ? decoded.whereType<Map<dynamic, dynamic>>().toList()
        : const [];
  } on FormatException {
    return const [];
  }
}

Map<dynamic, dynamic> _props(Map<dynamic, dynamic> object) =>
    ((object['info'] as Map?)?['props'] as Map?) ?? const {};

/// The node id of the node named [name], if it exists.
int? nodeIdNamed(String json, String name) {
  for (final o in _objects(json)) {
    if (o['id'] is int && _props(o)['node.name'] == name) return o['id'] as int;
  }
  return null;
}

/// Whether the playback stream with [props] is this app's own.
///
/// A sandbox reports a namespaced pid that need not match ours, so the binary
/// name, which reads the same inside and out, counts too.
bool _isOwnStream(Map<dynamic, dynamic> props, int processId, String? binary) =>
    '${props['application.process.id']}' == '$processId' ||
    (binary != null && props['application.process.binary'] == binary);

/// Every app playback stream except this app's own, with its output ports.
///
/// Streams that name no application are the sound server's own plumbing
/// (a filter chain feeding the hardware) and would play twice if mixed in.
List<PlaybackStream> foreignPlayback(
  String json,
  int processId, {
  String? binary,
}) {
  final objects = _objects(json);
  final streams = <int>{
    for (final o in objects)
      if (o['id'] is int &&
          _props(o)['media.class'] == 'Stream/Output/Audio' &&
          _props(o)['application.name'] != null &&
          !_isOwnStream(_props(o), processId, binary))
        o['id'] as int,
  };
  final ports = <int, List<int>>{};
  for (final o in objects) {
    final props = _props(o);
    final node = props['node.id'];
    if (o['id'] is int &&
        node is int &&
        streams.contains(node) &&
        props['port.direction'] == 'out') {
      ports.putIfAbsent(node, () => []).add(o['id'] as int);
    }
  }
  return [for (final e in ports.entries) (nodeId: e.key, outPorts: e.value)];
}

/// The mix node's input ports and the output ports already linked to it.
MixState mixState(String json, int mixNode) {
  final objects = _objects(json);
  final inPorts = [
    for (final o in objects)
      if (o['id'] is int &&
          _props(o)['node.id'] == mixNode &&
          _props(o)['port.direction'] == 'in')
        o['id'] as int,
  ];
  final linked = <int>{
    for (final o in objects)
      if (_props(o)['link.input.node'] == mixNode &&
          _props(o)['link.output.port'] is int)
        _props(o)['link.output.port'] as int,
  };
  return (inPorts: inPorts, linkedOutPorts: linked);
}

/// The mix inputs, `FL` and `FR`, that a stream port on [channel] feeds.
///
/// Mono and centre feed both; left and right surround variants fold into
/// their side; an unlabelled lone port is taken as mono; the rest is dropped.
List<String> mixChannelsFor(String? channel, {required bool onlyPort}) {
  switch (channel) {
    case 'FL' || 'RL' || 'SL' || 'FLC' || 'RLC':
      return const ['FL'];
    case 'FR' || 'RR' || 'SR' || 'FRC' || 'RRC':
      return const ['FR'];
    case 'MONO' || 'FC' || 'RC':
      return const ['FL', 'FR'];
    case null:
      return onlyPort ? const ['FL', 'FR'] : const [];
    default:
      return const [];
  }
}

/// Each port's `audio.channel`.
Map<int, String> channelsOf(String json) => {
      for (final o in _objects(json))
        if (o['id'] is int && _props(o)['audio.channel'] is String)
          o['id'] as int: _props(o)['audio.channel'] as String,
    };
