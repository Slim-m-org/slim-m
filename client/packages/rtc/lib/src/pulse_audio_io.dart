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

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'pulse_audio_parse.dart';
import 'voice_models.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

typedef PactlRunner = Future<ProcessResult> Function(List<String> args);

/// The lines `pactl subscribe` prints for as long as it is listened to.
typedef PactlSubscriber = Stream<String> Function();

typedef ProcessStarter = Future<Process> Function(
    String executable, List<String> arguments);

/// Runs `pactl subscribe` while listened to; [start] is a seam for tests.
@visibleForTesting
Stream<String> subscribePactl({ProcessStarter start = Process.start}) {
  Process? process;
  var cancelled = false;
  late final StreamController<String> lines;
  lines = StreamController<String>(
    onListen: () async {
      try {
        final started = await start('pactl', ['subscribe']);
        if (cancelled) {
          started.kill();
          return;
        }
        process = started;
        unawaited(started.stderr.drain<void>());
        unawaited(started.exitCode.then((code) {
          if (cancelled) return;
          AppLog.warning(LogTag.voice,
              'pactl subscribe exited with code $code; device changes are no longer followed');
        }));
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
    onCancel: () {
      cancelled = true;
      process?.kill();
    },
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
        _subscribe = subscribe ?? subscribePactl,
        _pid = processId ?? pid,
        _enabled = run != null || supported;

  /// A sound server that has no devices and never speaks, for tests.
  factory PulseAudio.inert() => PulseAudio(
        run: (_) async => ProcessResult(0, 1, '', ''),
        subscribe: () => const Stream.empty(),
      );

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

  /// Fires when a playback stream of this process starts. libwebrtc opens a new
  /// one when the room empties and refills, and it starts on the server default.
  Stream<void> get ownPlaybackStarts => _enabled
      ? _subscribe()
          .map(newSinkInputIndex)
          .where((index) => index != null)
          .asyncMap((index) => _isOwnSinkInput(index!))
          .where((own) => own)
          .map((_) {})
      : const Stream.empty();

  Future<bool> _isOwnSinkInput(int index) async {
    try {
      final listed = await _run(['-f', 'json', 'list', 'sink-inputs']);
      return listed.exitCode == 0 &&
          ownStreamIds(listed.stdout as String, _pid).contains(index);
    } on Object catch (error, stack) {
      AppLog.swallowed(LogTag.voice,
          'Could not tell whose playback stream started', error, stack);
      return false;
    }
  }

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
}
