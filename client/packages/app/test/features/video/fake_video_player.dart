// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A player that records every command and plays whatever events a test
/// sends it, standing in for a webview no widget test can host.
library;

import 'dart:async';

import 'package:slimm_app/src/features/video/providers/docked_video_player.dart';
import 'package:slimm_app/src/features/video/providers/embedded_video_player.dart';

class FakeVideoPlayer implements DockedVideoPlayer {
  final _events = StreamController<VideoPlayerEvent>.broadcast(sync: true);
  final loads = <({String id, Duration start})>[];
  final bounds = <NativeViewRect>[];
  final visibility = <bool>[];
  int plays = 0;
  int pauses = 0;
  int fullscreenExits = 0;
  Duration reported = Duration.zero;
  bool disposed = false;

  bool? get visible => visibility.isEmpty ? null : visibility.last;

  void emit(VideoPlayerEvent event) => _events.add(event);

  @override
  Stream<VideoPlayerEvent> get events => _events.stream;

  @override
  Future<void> load(String videoId, {Duration start = Duration.zero}) async =>
      loads.add((id: videoId, start: start));

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> seekTo(Duration position) async => reported = position;

  @override
  Future<Duration> position() async => reported;

  @override
  Future<void> setBounds(NativeViewRect rect) async => bounds.add(rect);

  @override
  Future<void> setVisible(bool visible) async => visibility.add(visible);

  @override
  Future<void> exitFullscreen() async => fullscreenExits++;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }
}
