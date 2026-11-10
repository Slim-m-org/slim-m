// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A player that reports a clip 83 seconds long, 12 seconds in, and a source
/// that hands it a media item at once, so the inline video row and its
/// playback bar render in a headless test (libmpv needs a GL texture there).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/attachment_video_player.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_video_source.dart';
import 'package:slimm_app/src/features/voice/widgets/video_playback_controls.dart';

import '../features/messages/attachment_video_fakes.dart';

class ReviewPlayer implements Player {
  @override
  final PlayerState state = const PlayerState(
    duration: Duration(seconds: 83),
    position: Duration(seconds: 12),
  );

  @override
  late final PlayerStream stream = _ReviewStream();

  @override
  Future<void> open(Playable playable, {bool play = true}) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> dispose({bool synchronized = true}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _ReviewStream implements PlayerStream {
  @override
  Stream<bool> get playing => const Stream.empty();

  @override
  Stream<bool> get buffering => const Stream.empty();

  @override
  Stream<String> get error => const Stream.empty();

  @override
  Stream<Duration> get position => const Stream.empty();

  @override
  Stream<Duration> get duration => const Stream.empty();

  @override
  Stream<double> get volume => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _OpensAtOnce implements AttachmentVideoSource {
  @override
  Future<Media> open({
    required api.SlimmApi apiClient,
    required api.Attachment attachment,
    required void Function(double? progress) onProgress,
  }) async => Media('https://example.invalid/clip.mp4');

  @override
  bool isStale(api.SlimmApi apiClient) => false;

  @override
  void dispose() {}
}

/// Overrides that make the inline player ready, drawing [frame] as the video
/// picture under the real playback bar.
List<Override> readyVideo(Widget frame) => [
  attachmentVideoSourceProvider.overrideWithValue(_OpensAtOnce.new),
  attachmentPlayerProvider.overrideWithValue(ReviewPlayer.new),
  attachmentVideoControllerProvider.overrideWithValue(
    (_) => FakeVideoController(),
  ),
  attachmentVideoSurfaceProvider.overrideWithValue(
    (player, controller, onToggleFullscreen, onSave, saving) =>
        VideoPlaybackControls(
          player: player,
          isFullscreen: false,
          onToggleFullscreen: onToggleFullscreen,
          onSave: onSave,
          saving: saving,
          child: frame,
        ),
  ),
];

/// Overrides that make the inline player's source fail with [error].
List<Override> failingVideo(Object error) => [
  attachmentVideoSourceProvider.overrideWithValue(
    () => ScriptedSource([error]),
  ),
  attachmentPlayerProvider.overrideWithValue(ReviewPlayer.new),
  attachmentVideoControllerProvider.overrideWithValue(
    (_) => FakeVideoController(),
  ),
];
