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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'pulse_audio_parse.dart';
import 'voice_models.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

typedef PactlRunner = Future<ProcessResult> Function(List<String> args);

/// The lines `pactl subscribe` prints for as long as it is listened to.
typedef PactlSubscriber = Stream<String> Function();

Stream<String> _subscribePactl() {
  Process? process;
  late final StreamController<String> lines;
  lines = StreamController<String>(
    onListen: () async {
      try {
        final started = process = await Process.start('pactl', ['subscribe']);
        unawaited(started.stderr.drain<void>());
        started.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(lines.add, onDone: lines.close);
      } on Object catch (error, stack) {
        AppLog.swallowed(LogTag.voice,
            'Could not watch the sound server with pactl', error, stack);
        await lines.close();
      }
    },
    onCancel: () => process?.kill(),
  );
  return lines.stream;
}

Future<ProcessResult> _runPactl(List<String> args) =>
    Process.run('pactl', args);

class PulseAudio {
  /// Whether this platform has a sound server to ask.
  static bool get supported => Platform.isLinux;

  PulseAudio({PactlRunner? run, PactlSubscriber? subscribe, int? processId})
      : _run = run ?? _runPactl,
        _subscribe = subscribe ?? _subscribePactl,
        _pid = processId ?? pid,
        _enabled = run != null || supported;

  final PactlRunner _run;
  final PactlSubscriber _subscribe;
  final int _pid;

  /// Off Linux nothing is ever spawned, so a phone never tries to start a process.
  final bool _enabled;

  /// Fires when a source or sink appears or goes, or the default moves.
  /// libwebrtc reports none of these on Linux, so a hot-plug was never seen.
  Stream<void> get deviceChanges => _enabled
      ? _subscribe().where(isDeviceEvent).map((_) {})
      : const Stream.empty();

  /// Recording sources, or null when `pactl` is missing or fails.
  Future<List<AudioDevice>?> sources() async => _list('sources', parseSources);

  /// Playback sinks, or null when `pactl` is missing or fails.
  Future<List<AudioDevice>?> sinks() async => _list('sinks', parseSinks);

  Future<List<AudioDevice>?> _list(
    String kind,
    List<AudioDevice> Function(String) parse,
  ) async {
    if (!_enabled) return null;
    try {
      final result = await _run(['-f', 'json', 'list', kind]);
      if (result.exitCode != 0) return null;
      return parse(result.stdout as String);
    } on Object catch (error, stack) {
      AppLog.swallowed(LogTag.voice, 'Could not list audio devices with pactl',
          error, stack);
      return null;
    }
  }

  /// The server's current default source or sink, as a device id.
  Future<String?> defaultNode({required bool capture}) async {
    if (!_enabled) return null;
    try {
      final result =
          await _run([capture ? 'get-default-source' : 'get-default-sink']);
      final name = (result.stdout as String).trim();
      return result.exitCode == 0 && name.isNotEmpty
          ? '$pulseDevicePrefix$name'
          : null;
    } on Object catch (error, stack) {
      AppLog.swallowed(LogTag.voice,
          'Could not read the default audio device with pactl', error, stack);
      return null;
    }
  }

  /// Moves this process's capture streams (or playback streams) onto the
  /// node [deviceId] names. Answers whether there was anything to move.
  Future<bool> moveOwnStreams({
    required bool capture,
    required String deviceId,
  }) async {
    if (!_enabled) return false;
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

  /// Runs one `pactl` command; its output, or null when it is missing or fails.
  Future<String?> pactl(List<String> args) async {
    if (!_enabled) return null;
    try {
      final result = await _run(args);
      return result.exitCode == 0 ? result.stdout as String : null;
    } on Object catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice, 'pactl ${args.first} failed', error, stack);
      return null;
    }
  }

  /// This process's id, which names its playback streams to the sound server.
  int get processId => _pid;
}
