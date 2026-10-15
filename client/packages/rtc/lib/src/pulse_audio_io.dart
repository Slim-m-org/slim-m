// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Microphones and speakers on Linux, read from the sound server itself.
///
/// On some PipeWire desktops libwebrtc's own device module lists no audio
/// devices at all while capture still works on the default one (seen on the
/// owner's Fedora KDE box, 2026-10-15), so the picker showed only "System
/// default" and a pick could never take. `pactl` speaks to PipeWire and
/// PulseAudio alike, so the list comes from there, and a pick moves this
/// process's own streams, which is what a desktop volume mixer does.
library;

import 'dart:io';

import 'pulse_audio_parse.dart';
import 'voice_models.dart';

typedef PactlRunner = Future<ProcessResult> Function(List<String> args);

Future<ProcessResult> _runPactl(List<String> args) =>
    Process.run('pactl', args);

class PulseAudio {
  /// Whether this platform has a sound server to ask.
  static bool get supported => Platform.isLinux;

  PulseAudio({PactlRunner? run, int? processId})
      : _run = run ?? _runPactl,
        _pid = processId ?? pid;

  final PactlRunner _run;
  final int _pid;

  /// Recording sources, or null when `pactl` is missing or fails.
  Future<List<AudioDevice>?> sources() async => _list('sources', parseSources);

  /// Playback sinks, or null when `pactl` is missing or fails.
  Future<List<AudioDevice>?> sinks() async => _list('sinks', parseSinks);

  Future<List<AudioDevice>?> _list(
    String kind,
    List<AudioDevice> Function(String) parse,
  ) async {
    try {
      final result = await _run(['-f', 'json', 'list', kind]);
      if (result.exitCode != 0) return null;
      return parse(result.stdout as String);
    } on Object {
      return null;
    }
  }

  /// The server's current default source or sink, as a device id.
  Future<String?> defaultNode({required bool capture}) async {
    try {
      final result =
          await _run([capture ? 'get-default-source' : 'get-default-sink']);
      final name = (result.stdout as String).trim();
      return result.exitCode == 0 && name.isNotEmpty
          ? '$pulseDevicePrefix$name'
          : null;
    } on Object {
      return null;
    }
  }

  /// Moves this process's capture streams (or playback streams) onto the
  /// node [deviceId] names. Answers whether there was anything to move.
  Future<bool> moveOwnStreams({
    required bool capture,
    required String deviceId,
  }) async {
    final node = deviceId.substring(pulseDevicePrefix.length);
    final kind = capture ? 'source-outputs' : 'sink-inputs';
    final listed = await _run(['-f', 'json', 'list', kind]);
    if (listed.exitCode != 0) return false;
    final ids = ownStreamIds(listed.stdout as String, _pid);
    for (final id in ids) {
      await _run(
          [capture ? 'move-source-output' : 'move-sink-input', '$id', node]);
    }
    return ids.isNotEmpty;
  }
}
