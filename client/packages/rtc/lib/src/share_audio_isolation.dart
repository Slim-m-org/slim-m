// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the call's own playout out of shared desktop audio on Linux.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show compute;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'share_audio_graph.dart';
import 'share_audio_graph_parse.dart';

export 'share_audio_graph_parse.dart' show shareMixNode;

/// What the share capture records instead of the default output's monitor; the Linux runner exports it once at startup.
const shareMixSource = '$shareMixNode.monitor';

/// Bounds the unlink-and-check rounds before the mix goes regardless.
const _emptyPasses = 5;

/// Every isolation from the start of its [ShareAudioIsolation.begin] to its end.
final _live = <ShareAudioIsolation>{};

/// Ends every share's mix still up, for an app about to quit or restart; gives up after [within].
/// The mix goes with the process otherwise, links and all, and WirePlumber pauses each player still feeding it.
Future<void> endShareAudioBeforeExit({
  Duration within = const Duration(seconds: 2),
}) async {
  final ending = [for (final isolation in _live.toList()) isolation.end()];
  if (ending.isEmpty) return;
  try {
    await Future.wait(ending).timeout(within);
  } on Object catch (error, stack) {
    AppLog.swallowed(
        LogTag.voice, 'Could not end share audio before exit', error, stack);
  }
}

/// Builds, for the length of a share, a private mix of every app's audio but this app's own.
/// Like venmic it only adds a node and links; the default output and every stream's routing stay as they were.
///
/// [begin] and [end] run one at a time, and an [end] that arrives while a [begin] is
/// still starting makes it tear down what it built, so no mix outlives its share.
class ShareAudioIsolation {
  ShareAudioIsolation({
    ShareAudioGraph? graph,
    this.followEvery = const Duration(seconds: 5),
    this.settleAfterStart = const [
      Duration(milliseconds: 250),
      Duration(seconds: 1),
    ],
    this.emptyWithin = const Duration(milliseconds: 1500),
  }) : _graph = graph ?? PipewireShareGraph();

  final ShareAudioGraph _graph;

  /// How often the graph is read when no new stream was announced, a backstop for one that was missed.
  final Duration followEvery;

  /// When to link after an app announces a new stream, since its ports appear a moment later.
  final List<Duration> settleAfterStart;

  /// How long ending a share waits for the mix to empty before removing it anyway, so a wedged sound server cannot hold up stopping the share or leaving the call.
  final Duration emptyWithin;
  int? _mixNode;
  Timer? _follow;
  StreamSubscription<void>? _starts;
  final _settling = <Timer>[];
  Future<void>? _linking;
  // Null while idle, so no future is made in whichever zone built this object.
  Future<void>? _queue;
  int _ends = 0;

  bool get active => _mixNode != null;

  /// Whether this platform has a sound server to drive at all; false means there is nothing to isolate.
  bool get supported => _graph.supported;

  /// Returns false, changing nothing, when the sound server cannot be driven.
  Future<bool> begin() => _serially(_begin);

  Future<void> end() {
    _ends++;
    return _serially(_end);
  }

  Future<T> _serially<T>(Future<T> Function() run) {
    final pending = _queue;
    final result = pending == null ? run() : pending.then((_) => run());
    final tail = _queue = result.then<void>((_) {}, onError: (Object _) {});
    unawaited(tail.whenComplete(() {
      if (identical(_queue, tail)) _queue = null;
    }));
    return result;
  }

  Future<bool> _begin() async {
    if (active) return true;
    if (!_graph.supported) return false;
    _live.add(this);
    final up = await _bringUp();
    if (!up) _live.remove(this);
    return up;
  }

  Future<bool> _bringUp() async {
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
    await _link();
    _follow = Timer.periodic(followEvery, (_) => unawaited(_link()));
    _starts = _graph.playbackStarts.listen((_) => _linkSoon());
    return true;
  }

  Future<void> _end() async {
    _live.remove(this);
    _follow?.cancel();
    _follow = null;
    unawaited(_starts?.cancel());
    _starts = null;
    for (final timer in _settling) {
      timer.cancel();
    }
    _settling.clear();
    final mix = _mixNode;
    if (mix == null) return;
    _mixNode = null;
    try {
      await _unhook(mix).timeout(emptyWithin, onTimeout: () {
        AppLog.warning(LogTag.voice,
            'The share mix did not empty in time; media players feeding it may pause');
      });
    } finally {
      await _graph.destroy();
    }
  }

  Future<void> _unhook(int mix) async {
    await _linking;
    await _empty(mix);
  }

  /// WirePlumber pauses every media player still feeding a sink that goes away, Spotify included.
  Future<void> _empty(int mix) async {
    for (var pass = 0; pass < _emptyPasses; pass++) {
      final dump = await _graph.dump();
      if (dump == null) return;
      final links = ShareGraphSnapshot.parse(dump).mixState(mix).links;
      if (links.isEmpty) return;
      await Future.wait([
        for (final link in links) _graph.unlink(link.out, link.input),
      ]);
    }
  }

  void _notIsolated(String why) => AppLog.warning(
      LogTag.voice, 'Share audio is not isolated from the call: $why');

  Future<int?> _awaitMix(bool Function() ended) async {
    for (var i = 0; i < 30 && !ended(); i++) {
      final dump = await _graph.dump();
      final snapshot = dump == null ? null : ShareGraphSnapshot.parse(dump);
      final node = snapshot?.nodeIdNamed(shareMixNode);
      if (node != null && snapshot!.mixState(node).inPorts.isNotEmpty) {
        return node;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  /// Links every other app's playback into the mix; ones already linked are skipped, ones that left drop their own links.
  Future<void> _link() {
    final mix = _mixNode;
    if (mix == null) return Future.value();
    return _linking ??= _linkInto(mix).whenComplete(() => _linking = null);
  }

  void _linkSoon() {
    for (final delay in settleAfterStart) {
      late final Timer timer;
      timer = Timer(delay, () {
        _settling.remove(timer);
        unawaited(_link());
      });
      _settling.add(timer);
    }
  }

  Future<void> _linkInto(int mix) async {
    final dump = await _graph.dump();
    if (dump == null || !active) return;
    final wanted = await compute(mixLinksToMake, (
      dump: dump,
      mix: mix,
      processId: _graph.processId,
      binary: _graph.executableName,
    ));
    for (final link in wanted) {
      if (!active) return;
      await _graph.link(link.out, link.input);
    }
  }
}
