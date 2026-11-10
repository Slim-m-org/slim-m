// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of video in messages: the inline player (ready and
/// failed) in the real transcript, and the full screen route with its
/// playback bar shown and hidden. The full screen route pins a dark palette
/// over an opaque black field, so it writes the dark capture only. PNGs are
/// written only under SLIMM_UI_SNAPSHOTS=1; otherwise each case asserts a
/// clean layout.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/attachment_video_fullscreen.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_messages_media.dart';
import 'ui_review_messages_support.dart';
import 'ui_review_messages_video.dart';

const _ada = 'user-ada';

const _clip = api.Attachment(
  id: 'clip-demo',
  filename: 'canvas-demo.mp4',
  contentType: 'video/mp4',
  size: 12582912,
);

List<api.Message> _withClip() => [
  reviewMessage(1, _ada, 'recorded the canvas demo for the offsite'),
  reviewMessage(2, _ada, 'about a minute long', attachments: [_clip]),
];

Widget _frame() => Image.memory(
  photo(2, w: 1280, h: 720),
  fit: BoxFit.cover,
  width: double.infinity,
  height: double.infinity,
);

late Player _player;

Future<void> _openFullscreen(ReviewScene scene) async {
  await showFullscreenAttachmentVideo(
    scene.context,
    player: _player,
    controller: VideoController(_player),
    filename: _clip.filename,
  );
}

Future<void> _openAndHover(ReviewScene scene) async {
  unawaited(_openFullscreen(scene));
  await scene.frames(3);
  final mouse = await scene.tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(scene.tester.view.physicalSize.center(Offset.zero));
  await scene.frames(2);
}

Future<void> _openAndTap(ReviewScene scene) async {
  unawaited(_openFullscreen(scene));
  await scene.frames(3);
  await scene.tester.tapAt(scene.tester.view.physicalSize.center(Offset.zero));
  await scene.frames(2);
}

Future<void> _openOnly(ReviewScene scene) async {
  unawaited(_openFullscreen(scene));
  await scene.frames(3);
}

void main() {
  setUpAll(() async {
    await loadRealFonts();
    MediaKit.ensureInitialized();
    _player = Player();
  });

  for (final viewport in reviewViewports.keys) {
    testWidgets('inline video at $viewport', (tester) async {
      await captureMessages(
        tester,
        surface: 'msg-attachments',
        state: 'video-inline',
        viewport: viewport,
        messages: _withClip(),
        overrides: readyVideo(_frame()),
      );
    });

    testWidgets('inline video error at $viewport', (tester) async {
      await captureMessages(
        tester,
        surface: 'msg-attachments',
        state: 'video-error',
        viewport: viewport,
        messages: _withClip(),
        overrides: failingVideo(
          const api.ConnectionDroppedException('connection dropped'),
        ),
      );
    });

    testWidgets('fullscreen controls at $viewport', (tester) async {
      await captureMessages(
        tester,
        surface: 'overlay-fullscreen-attachment-video',
        state: 'controls',
        viewport: viewport,
        messages: _withClip(),
        themes: const ['dark'],
        act: viewport == 'phone' ? _openOnly : _openAndHover,
      );
    });

    testWidgets('fullscreen controls hidden at $viewport', (tester) async {
      await captureMessages(
        tester,
        surface: 'overlay-fullscreen-attachment-video',
        state: 'controls-hidden',
        viewport: viewport,
        messages: _withClip(),
        themes: const ['dark'],
        act: viewport == 'phone' ? _openAndTap : _openOnly,
      );
    });
  }
}
