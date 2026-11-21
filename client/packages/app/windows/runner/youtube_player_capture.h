// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_CAPTURE_H_
#define RUNNER_YOUTUBE_PLAYER_CAPTURE_H_

#include <windows.h>
#include <dxgi.h>
#include <unknwn.h>

#include <functional>
#include <memory>

/// The WebView2 player's frames as a shared D3D11 texture Flutter can draw:
/// WebView2 renders into a composition visual that is never shown, and
/// Windows.Graphics.Capture copies each frame of it out. C++/WinRT throws,
/// so this lives in the player's own library with exceptions on.
namespace slimm_youtube {

struct SharedFrame {
  HANDLE handle = nullptr;
  UINT width = 0;
  UINT height = 0;
};

class VisualCapture {
 public:
  /// Whether this Windows can capture a visual (10 1903 or newer).
  static bool Supported();

  /// Builds the visual WebView2 renders into on [adapter], Flutter's own,
  /// and calls [on_frame] from a worker thread after each new frame. Null
  /// when any part of that is missing.
  static std::shared_ptr<VisualCapture> Create(IDXGIAdapter* adapter,
                                               std::function<void()> on_frame);

  virtual ~VisualCapture() = default;

  /// The visual to hand WebView2 as its root visual target.
  virtual IUnknown* RootVisual() = 0;

  /// Sizes the visual in physical pixels; capture follows on the next frame.
  virtual void Resize(UINT width, UINT height) = 0;

  /// The newest frame; safe from any thread.
  virtual SharedFrame Latest() = 0;
};

}  // namespace slimm_youtube

#endif  // RUNNER_YOUTUBE_PLAYER_CAPTURE_H_
