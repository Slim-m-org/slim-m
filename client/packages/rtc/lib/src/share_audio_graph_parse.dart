// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading `pw-dump` output for the share mix; see `share_audio_isolation.dart`.
library;

import 'dart:convert';

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

/// Every app playback stream except this process's own, with its output ports.
List<PlaybackStream> foreignPlayback(String json, int processId) {
  final objects = _objects(json);
  final streams = <int>{
    for (final o in objects)
      if (o['id'] is int &&
          _props(o)['media.class'] == 'Stream/Output/Audio' &&
          '${_props(o)['application.process.id']}' != '$processId')
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

/// Ports sorted so the same channel pairs with the same channel.
Map<int, String> channelsOf(String json) => {
      for (final o in _objects(json))
        if (o['id'] is int && _props(o)['audio.channel'] is String)
          o['id'] as int: _props(o)['audio.channel'] as String,
    };
