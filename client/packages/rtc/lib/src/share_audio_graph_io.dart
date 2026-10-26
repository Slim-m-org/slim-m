// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drives PipeWire with its own command line tools, the way venmic drives it as a client.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'share_audio_graph.dart';

typedef _SetEnv = int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, int);
typedef _UnsetEnv = int Function(ffi.Pointer<Utf8>);

const _captureSourceVariable = 'SLIMM_SHARE_AUDIO_SOURCE';

class PipewireShareGraph implements ShareAudioGraph {
  /// Holds the connection that owns the mix: PipeWire removes what a client made when it goes, a crash included.
  Process? _owner;

  @override
  bool get supported => Platform.isLinux;

  @override
  int get processId => pid;

  @override
  Future<bool> createMix(String name) async {
    try {
      final owner = _owner = await Process.start('pw-cli', const []);
      unawaited(owner.stdout.drain<void>());
      unawaited(owner.stderr.drain<void>());
      owner.stdin.writeln(
        'create-node adapter { factory.name=support.null-audio-sink '
        'node.name=$name node.description=slim-m-share-mix '
        'media.class=Audio/Sink audio.position=[FL FR] object.linger=false '
        'priority.session=0 priority.driver=0 node.virtual=true }',
      );
      await owner.stdin.flush();
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
  void exportCaptureSource(String? source) {
    final libc = ffi.DynamicLibrary.process();
    final key = _captureSourceVariable.toNativeUtf8();
    try {
      if (source == null) {
        libc.lookupFunction<ffi.Int32 Function(ffi.Pointer<Utf8>), _UnsetEnv>(
            'unsetenv')(key);
        return;
      }
      final value = source.toNativeUtf8();
      try {
        libc.lookupFunction<
            ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Int32),
            _SetEnv>('setenv')(key, value, 1);
      } finally {
        malloc.free(value);
      }
    } finally {
      malloc.free(key);
    }
  }

  @override
  Future<void> destroy() async {
    final owner = _owner;
    _owner = null;
    if (owner == null) return;
    owner.kill();
    await owner.exitCode;
  }
}
