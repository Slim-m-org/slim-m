// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading `pactl -f json` output; see `pulse_audio_io.dart` for why.
library;

import 'dart:convert';

import 'voice_models.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// Marks an [AudioDevice.id] as a sound server node name rather than a
/// libwebrtc device id, so a switch knows which way to apply it.
const String pulseDevicePrefix = 'pulse:';

/// Whether [id] names a sound server node rather than a libwebrtc device.
bool isPulseDeviceId(String? id) =>
    id != null && id.startsWith(pulseDevicePrefix);

List<dynamic> _decode(String json) {
  try {
    final decoded = jsonDecode(json);
    return decoded is List ? decoded : const [];
  } on FormatException catch (error, stack) {
    AppLog.swallowed(LogTag.voice,
        'pactl returned output that is not valid JSON', error, stack);
    return const [];
  }
}

String _label(Map<dynamic, dynamic> node) {
  final description = node['description'];
  return description is String && description.trim().isNotEmpty
      ? description
      : node['name'] as String;
}

/// Real recording sources: sink monitors are left out, since picking "the
/// speakers" as a microphone is never what a person means here.
List<AudioDevice> parseSources(String json) => [
      for (final node in _decode(json).whereType<Map<dynamic, dynamic>>())
        if (node['name'] is String &&
            (node['monitor_source'] ?? '') == '' &&
            !(node['name'] as String).endsWith('.monitor'))
          AudioDevice(
              id: '$pulseDevicePrefix${node['name']}', label: _label(node)),
    ];

List<AudioDevice> parseSinks(String json) => [
      for (final node in _decode(json).whereType<Map<dynamic, dynamic>>())
        if (node['name'] is String)
          AudioDevice(
              id: '$pulseDevicePrefix${node['name']}', label: _label(node)),
    ];

/// The stream indexes this process owns among `pactl -f json list
/// source-outputs` (or sink-inputs) output.
List<int> ownStreamIds(String json, int processId) => [
      for (final stream in _decode(json).whereType<Map<dynamic, dynamic>>())
        if (stream['index'] is int &&
            (stream['properties'] as Map?)?['application.process.id'] ==
                '$processId')
          stream['index'] as int,
    ];

/// Whether a `pactl subscribe` line is a device appearing or going, or the
/// default moving; volume and state changes on a device are noise here.
bool isDeviceEvent(String line) => RegExp(
      r"^Event '(new|remove)' on (source|sink) #\d+$|^Event 'change' on server$",
    ).hasMatch(line.trim());
