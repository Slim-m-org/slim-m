// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drives PipeWire with its own command line tools, the way venmic drives it as a client.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'pulse_audio_io.dart' show sandboxedExecutableName, subscribePactl;
import 'pulse_audio_parse.dart' show newSinkInputIndex;
import 'share_audio_graph.dart';

const _daemonProbe = Duration(milliseconds: 400);
const _killGrace = Duration(seconds: 2);

class PipewireShareGraph implements ShareAudioGraph {
  PipewireShareGraph({@visibleForTesting this.cli = 'pw-cli'});

  final String cli;

  /// Holds the connection that owns the mix: PipeWire removes what a client made when it goes, a crash included.
  Process? _owner;

  @override
  bool get supported => Platform.isLinux;

  @override
  int get processId => pid;

  @override
  String? get executableName => sandboxedExecutableName();

  @override
  Future<bool> createMix(String name) async {
    await destroy();
    try {
      final owner = _owner = await Process.start(cli, const []);
      final connected = Completer<bool>();
      owner.stdout.listen(
        (_) {
          if (!connected.isCompleted) connected.complete(true);
        },
        onDone: () {
          if (!connected.isCompleted) connected.complete(false);
        },
      );
      unawaited(owner.stdin.done.catchError((Object e, StackTrace st) {
        AppLog.swallowed(LogTag.voice, 'pw-cli closed its input', e, st);
      }));
      final failure = owner.stderr.transform(utf8.decoder).join();
      owner.stdin.writeln(
        'create-node adapter { factory.name=support.null-audio-sink '
        'node.name=$name node.description=slim-m-share-mix '
        'media.class=Audio/Sink audio.position=[FL FR] object.linger=false '
        'priority.session=0 priority.driver=0 node.virtual=true }',
      );
      // pw-cli greets on stdout once it has a daemon and leaves at once without one.
      final alive =
          await connected.future.timeout(_daemonProbe, onTimeout: () => true);
      if (!alive) {
        _owner = null;
        AppLog.warning(LogTag.voice,
            'pw-cli exited at once, the sound server is not reachable: ${(await failure).trim()}');
        return false;
      }
      return true;
    } on Object catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice, 'Could not create the share mix', error, stack);
      return false;
    }
  }

  @override
  Future<String?> dump() async {
    try {
      final result =
          await Process.run('pw-dump', const [], stdoutEncoding: utf8);
      return result.exitCode == 0 ? result.stdout as String : null;
    } on Object catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice, 'Could not read the audio graph', error, stack);
      return null;
    }
  }

  @override
  Future<bool> link(int out, int input) async {
    try {
      final result = await Process.run('pw-link', ['$out', '$input']);
      return result.exitCode == 0;
    } on Object catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice, 'Could not link audio ports', error, stack);
      return false;
    }
  }

  @override
  Future<bool> unlink(int out, int input) async {
    try {
      final result = await Process.run('pw-link', ['-d', '$out', '$input']);
      return result.exitCode == 0;
    } on Object catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice, 'Could not unlink audio ports', error, stack);
      return false;
    }
  }

  @override
  Stream<void> get playbackStarts => subscribePactl()
      .where((line) => newSinkInputIndex(line) != null)
      .map((_) {});

  @override
  Future<void> destroy() async {
    final owner = _owner;
    _owner = null;
    if (owner == null) return;
    owner.kill();
    await owner.exitCode.timeout(_killGrace, onTimeout: () {
      owner.kill(ProcessSignal.sigkill);
      return -1;
    });
  }
}
