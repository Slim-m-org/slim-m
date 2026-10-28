// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser has no sound server graph to drive; see `share_audio_graph_io.dart`.
library;

import 'share_audio_graph.dart';

class PipewireShareGraph implements ShareAudioGraph {
  @override
  bool get supported => false;
  @override
  int get processId => 0;
  @override
  String? get executableName => null;
  @override
  Future<bool> createMix(String name) async => false;
  @override
  Future<String?> dump() async => null;
  @override
  Future<bool> link(int out, int input) async => false;
  @override
  void exportCaptureSource(String? source) {}
  @override
  Future<void> destroy() async {}
}
