// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_CHANNEL_H_
#define RUNNER_YOUTUBE_PLAYER_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

/// Serves `top.npcserver.slimm/youtube_player` (native_video_host.dart): the
/// YouTube panel's WebView2, a child of [view], the Flutter view's window, at
/// the rect Dart sends. "probe" answers false without the WebView2 runtime.
void RegisterYoutubePlayerChannel(flutter::BinaryMessenger* messenger,
                                  HWND view);

#endif  // RUNNER_YOUTUBE_PLAYER_CHANNEL_H_
