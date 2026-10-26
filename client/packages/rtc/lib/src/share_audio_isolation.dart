// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the call's own playout out of shared desktop audio on Linux.
library;

import 'dart:async';

import 'share_audio_graph.dart';
import 'share_audio_graph_parse.dart';

const shareMixNode = 'slimm-share-mix';

/// What the share capture records instead of the default output's monitor.
const shareMixSource = '$shareMixNode.monitor';

/// Builds, for the length of a share, a private mix of every app's audio but this process's own.
/// Like venmic it only adds a node and links; the default output and every stream's routing stay as they were.
class ShareAudioIsolation {
  ShareAudioIsolation({
    ShareAudioGraph? graph,
    this.followEvery = const Duration(seconds: 1),
  }) : _graph = graph ?? PipewireShareGraph();

  final ShareAudioGraph _graph;
  final Duration followEvery;
  int? _mixNode;
  Timer? _follow;
  bool _following = false;

  bool get active => _mixNode != null;

  /// Returns false, changing nothing, when the sound server cannot be driven.
  Future<bool> begin() async {
    if (active) return true;
    if (!_graph.supported || !await _graph.createMix(shareMixNode)) {
      return false;
    }
    _mixNode = await _awaitMix();
    if (_mixNode == null) {
      await _graph.destroy();
      return false;
    }
    _graph.exportCaptureSource(shareMixSource);
    await _link();
    _follow = Timer.periodic(followEvery, (_) => unawaited(_link()));
    return true;
  }

  Future<void> end() async {
    _follow?.cancel();
    _follow = null;
    if (!active) return;
    _graph.exportCaptureSource(null);
    _mixNode = null;
    await _graph.destroy();
  }

  Future<int?> _awaitMix() async {
    for (var i = 0; i < 30; i++) {
      final dump = await _graph.dump();
      final node = dump == null ? null : nodeIdNamed(dump, shareMixNode);
      if (node != null && mixState(dump!, node).inPorts.isNotEmpty) return node;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  /// Links every other app's playback into the mix; ones already linked are skipped, ones that left drop their own links.
  Future<void> _link() async {
    final mix = _mixNode;
    if (mix == null || _following) return;
    _following = true;
    try {
      final dump = await _graph.dump();
      if (dump == null || !active) return;
      final state = mixState(dump, mix);
      final channels = channelsOf(dump);
      for (final stream in foreignPlayback(dump, _graph.processId)) {
        for (final out in stream.outPorts) {
          if (state.linkedOutPorts.contains(out)) continue;
          final input = state.inPorts.where(
            (p) => channels[p] == channels[out],
          );
          if (input.isNotEmpty) await _graph.link(out, input.first);
        }
      }
    } finally {
      _following = false;
    }
  }
}
