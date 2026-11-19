// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_CHANNEL_H_
#define RUNNER_YOUTUBE_PLAYER_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

/// The native half of native_video_host.dart: one WebKitGTK view, laid over
/// the Flutter view inside [overlay] at the rect Dart sends, playing the
/// YouTube host page. "probe" answers false where WebKitGTK cannot load.
void youtube_player_channel_register(FlBinaryMessenger* messenger,
                                     GtkOverlay* overlay);

#endif  // RUNNER_YOUTUBE_PLAYER_CHANNEL_H_
