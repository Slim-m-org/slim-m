// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser has no sound server to ask; see `pulse_audio_io.dart`.
library;

import 'voice_models.dart';

typedef PactlRunner = Future<Object> Function(List<String> args);

class PulseAudio {
  PulseAudio({PactlRunner? run, int? processId});

  static bool get supported => false;

  Future<List<AudioDevice>?> sources() async => null;

  Future<List<AudioDevice>?> sinks() async => null;

  Future<String?> defaultNode({required bool capture}) async => null;

  Future<bool> moveOwnStreams(
          {required bool capture, required String deviceId}) async =>
      false;
}
