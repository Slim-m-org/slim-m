// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A player that records every command and plays whatever events a test
/// sends it, standing in for a webview no widget test can host.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:slimm_app/src/features/video/providers/desktop_video_player.dart';
import 'package:slimm_app/src/features/video/providers/embedded_video_player.dart';

class FakeVideoPlayer implements DesktopVideoPlayer {
  final _events = StreamController<VideoPlayerEvent>.broadcast(sync: true);
  final _texture = ValueNotifier<int?>(null);
  final loads = <({String id, Duration start})>[];
  final sizes = <(Size, double)>[];
  final pointers = <(VideoPointerKind, Offset)>[];
  int plays = 0;
  int pauses = 0;
  int fullscreenExits = 0;
  Duration reported = Duration.zero;
  bool disposed = false;

  /// The texture id the fake hands out once loaded.
  static const textureId = 7;

  Size? get size => sizes.isEmpty ? null : sizes.last.$1;

  void emit(VideoPlayerEvent event) => _events.add(event);

  @override
  Stream<VideoPlayerEvent> get events => _events.stream;

  @override
  ValueListenable<int?> get texture => _texture;

  @override
  Future<void> load(String videoId, {Duration start = Duration.zero}) async {
    loads.add((id: videoId, start: start));
    _texture.value = textureId;
  }

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> seekTo(Duration position) async => reported = position;

  @override
  Future<Duration> position() async => reported;

  @override
  Future<void> resize(Size size, double pixelRatio) async =>
      sizes.add((size, pixelRatio));

  @override
  Future<void> pointer(VideoPointerKind kind, Offset position) async =>
      pointers.add((kind, position));

  @override
  Future<void> exitFullscreen() async => fullscreenExits++;

  @override
  Future<void> dispose() async {
    disposed = true;
    _texture.value = null;
    await _events.close();
  }
}
