// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_CHANNEL_H_
#define RUNNER_YOUTUBE_PLAYER_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

/// The native half of native_video_host.dart: one WebKitGTK view playing the
/// YouTube host page, kept in [overlay] but outside the window, whose frames
/// Flutter draws as a texture from [registrar] wherever the player belongs.
/// "probe" answers false where WebKitGTK cannot load.
void youtube_player_channel_register(FlBinaryMessenger* messenger,
                                     FlTextureRegistrar* registrar,
                                     GtkOverlay* overlay);

#endif  // RUNNER_YOUTUBE_PLAYER_CHANNEL_H_
