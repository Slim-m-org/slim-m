// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two local media performance preferences that gate how much an inline
/// attachment does on its own before you ask.
///
/// [MediaAutoDownload] decides whether an image fetches the moment it scrolls
/// into view or waits to be tapped - the data lever, for a metered connection.
/// [GifAutoplay] decides whether a gif animates on its own or holds on its
/// first frame until hovered or tapped - the battery-and-CPU lever, since
/// animating gifs decode every frame forever. Downloading defaults to what
/// this app has always done; gifs default to held, at the owner's request,
/// since a busy channel full of looping gifs is the distracting case and a
/// hover or tap is all it takes to see one. Opening an attachment always
/// shows it fully regardless.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'preference_controller.dart';

/// Whether an inline image downloads on sight or waits for a tap.
enum MediaAutoDownload { always, manual }

/// Whether a gif animates on its own or waits for a hover or a tap.
enum GifAutoplay { autoplay, tapToPlay }

extension MediaAutoDownloadX on MediaAutoDownload {
  String get label => switch (this) {
    MediaAutoDownload.always => 'Always (default)',
    MediaAutoDownload.manual => 'Only when I tap',
  };
}

extension GifAutoplayX on GifAutoplay {
  String get label => switch (this) {
    GifAutoplay.autoplay => 'Always',
    GifAutoplay.tapToPlay => 'On hover or tap (default)',
  };
}

const mediaAutoDownloadKey = 'slimm.performance.media_autodownload';
const gifAutoplayKey = 'slimm.performance.gif_autoplay';

const defaultMediaAutoDownload = MediaAutoDownload.always;
const defaultGifAutoplay = GifAutoplay.tapToPlay;

class MediaAutoDownloadController
    extends EnumPreferenceController<MediaAutoDownload> {
  MediaAutoDownloadController(super.ref)
    : super(
        storageKey: mediaAutoDownloadKey,
        choices: MediaAutoDownload.values,
        fallback: defaultMediaAutoDownload,
      );
}

class GifAutoplayController extends EnumPreferenceController<GifAutoplay> {
  GifAutoplayController(super.ref)
    : super(
        storageKey: gifAutoplayKey,
        choices: GifAutoplay.values,
        fallback: defaultGifAutoplay,
      );
}

final mediaAutoDownloadControllerProvider =
    StateNotifierProvider<MediaAutoDownloadController, MediaAutoDownload>(
      MediaAutoDownloadController.new,
    );

final gifAutoplayControllerProvider =
    StateNotifierProvider<GifAutoplayController, GifAutoplay>(
      GifAutoplayController.new,
    );
