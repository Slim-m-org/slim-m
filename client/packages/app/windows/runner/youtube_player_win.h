// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_WIN_H_
#define RUNNER_YOUTUBE_PLAYER_WIN_H_

#include <windows.h>

#include <functional>
#include <string>

/// The WebView2 side of the YouTube panel: one view, a child of the Flutter
/// view's window, serving the host page from https://top.npcserver.slimm so
/// YouTube sees a referrer. Its own library because WebView2.h is not clean
/// under the runner's warnings-as-errors. Everything runs on the UI thread.
namespace slimm_youtube {

using MessageHandler = std::function<void(const std::string& json)>;

// Whether the Evergreen WebView2 runtime is installed; most Windows 10 and every Windows 11 machine has it.
bool RuntimeAvailable();

// Builds the view hidden and loads [html]; [done] says whether it worked.
void Create(HWND parent, const std::string& html, MessageHandler on_message,
            std::function<void(bool)> done);

void SetBounds(RECT physical);
void SetVisible(bool visible);
void Run(const std::string& script);
void Destroy();

}  // namespace slimm_youtube

#endif  // RUNNER_YOUTUBE_PLAYER_WIN_H_
