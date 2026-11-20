// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_CHANNEL_H_
#define RUNNER_YOUTUBE_PLAYER_CHANNEL_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

/// Serves `top.npcserver.slimm/youtube_player` (native_video_host.dart): the
/// YouTube player's WebView2, hosted off screen for [view], the Flutter
/// view's window, its frames a texture on [engine]'s own GPU that Flutter
/// draws wherever the player belongs. "probe" answers false without the
/// WebView2 runtime or visual capture.
void RegisterYoutubePlayerChannel(flutter::FlutterEngine* engine, HWND view);

#endif  // RUNNER_YOUTUBE_PLAYER_CHANNEL_H_
