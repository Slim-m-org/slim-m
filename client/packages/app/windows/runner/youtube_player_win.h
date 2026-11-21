// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_WIN_H_
#define RUNNER_YOUTUBE_PLAYER_WIN_H_

#include <windows.h>
#include <dxgi.h>

#include <functional>
#include <string>

#include "youtube_player_capture.h"

/// The WebView2 side of the YouTube player: one view hosted in a composition
/// visual that is captured into a texture rather than shown, serving the
/// host page from https://top.npcserver.slimm so YouTube sees a referrer.
/// Its own library because WebView2.h is not clean under the runner's
/// warnings-as-errors. Everything but frame capture runs on the UI thread.
namespace slimm_youtube {

using MessageHandler = std::function<void(const std::string& json)>;

enum class PointerKind { kEnter, kMove, kDown, kUp, kLeave };

// Whether the Evergreen WebView2 runtime is installed (most Windows 10 and every Windows 11 machine has it) and a visual can be captured.
bool RuntimeAvailable();

// Builds the view on [adapter] and loads [html]; [on_frame] runs on a worker thread per new frame, [done] says whether it worked.
void Create(HWND parent, IDXGIAdapter* adapter, const std::string& html,
            MessageHandler on_message, std::function<void()> on_frame,
            std::function<void(bool)> done);

// [width] and [height] are logical pixels, drawn at [scale] physical pixels to each.
void Resize(double width, double height, double scale);
void Pointer(PointerKind kind, double x, double y);
SharedFrame Latest();
void Run(const std::string& script);
void Destroy();

}  // namespace slimm_youtube

#endif  // RUNNER_YOUTUBE_PLAYER_WIN_H_
