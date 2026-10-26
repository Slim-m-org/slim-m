// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The PipeWire graph operations a share mix needs; a no-op on web.
library;

export 'share_audio_graph_web.dart'
    if (dart.library.io) 'share_audio_graph_io.dart';

/// What [ShareAudioIsolation] needs from the sound server, so tests can stand in for it.
abstract class ShareAudioGraph {
  /// Whether this host has a graph to drive.
  bool get supported;

  /// This process's id, which names its own playback streams.
  int get processId;

  /// Creates the private mix sink; it lives only as long as [destroy] has not run.
  Future<bool> createMix(String name);

  /// `pw-dump` output, or null when it is missing or fails.
  Future<String?> dump();

  /// Links output port [out] to input port [input]; true when it took.
  Future<bool> link(int out, int input);

  /// Points the share capture at the source named [source], or back to the default when null.
  void exportCaptureSource(String? source);

  /// Removes the mix, which takes every link into it along.
  Future<void> destroy();
}
