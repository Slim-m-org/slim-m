// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the call's own playout out of shared desktop audio on Linux.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'share_audio_graph.dart';
import 'share_audio_graph_parse.dart';

export 'share_audio_graph_parse.dart' show shareMixNode;

/// What the share capture records instead of the default output's monitor.
const shareMixSource = '$shareMixNode.monitor';

/// Builds, for the length of a share, a private mix of every app's audio but this app's own.
/// Like venmic it only adds a node and links; the default output and every stream's routing stay as they were.
///
/// [begin] and [end] run one at a time, and an [end] that arrives while a [begin] is
/// still starting makes it tear down what it built, so no mix outlives its share.
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
  Future<void> _queue = Future<void>.value();
  int _ends = 0;

  bool get active => _mixNode != null;

  /// Returns false, changing nothing, when the sound server cannot be driven.
  Future<bool> begin() => _serially(_begin);

  Future<void> end() {
    _ends++;
    return _serially(_end);
  }

  Future<T> _serially<T>(Future<T> Function() run) {
    final result = _queue.then((_) => run());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<bool> _begin() async {
    if (active) return true;
    if (!_graph.supported) return false;
    final ends = _ends;
    bool ended() => ends != _ends;
    if (!await _graph.createMix(shareMixNode)) {
      _notIsolated('the sound server would not make the mix');
      return false;
    }
    final node = ended() ? null : await _awaitMix(ended);
    if (node == null || ended()) {
      await _graph.destroy();
      if (!ended()) _notIsolated('the mix never appeared');
      return false;
    }
    _mixNode = node;
    _graph.exportCaptureSource(shareMixSource);
    await _link();
    _follow = Timer.periodic(followEvery, (_) => unawaited(_link()));
    return true;
  }

  Future<void> _end() async {
    _follow?.cancel();
    _follow = null;
    if (!active) return;
    _graph.exportCaptureSource(null);
    _mixNode = null;
    await _graph.destroy();
  }

  void _notIsolated(String why) => AppLog.warning(
      LogTag.voice, 'Share audio is not isolated from the call: $why');

  Future<int?> _awaitMix(bool Function() ended) async {
    for (var i = 0; i < 30 && !ended(); i++) {
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
      final foreign = foreignPlayback(
        dump,
        _graph.processId,
        binary: _graph.executableName,
      );
      for (final stream in foreign) {
        for (final out in stream.outPorts) {
          if (state.linkedOutPorts.contains(out)) continue;
          final wanted = mixChannelsFor(
            channels[out],
            onlyPort: stream.outPorts.length == 1,
          );
          for (final input in state.inPorts) {
            if (wanted.contains(channels[input])) await _graph.link(out, input);
          }
        }
      }
    } finally {
      _following = false;
    }
  }
}
