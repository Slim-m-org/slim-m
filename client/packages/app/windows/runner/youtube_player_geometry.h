// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_GEOMETRY_H_
#define RUNNER_YOUTUBE_PLAYER_GEOMETRY_H_

#include <cmath>
#include <string>

/// The YouTube panel's pure rules, kept free of Windows headers so
/// test/runner_logic_test.cpp can run them anywhere.
namespace slimm {

struct PixelRect {
  long left = 0;
  long top = 0;
  long right = 0;
  long bottom = 0;
};

// Flutter sends logical pixels; WebView2 bounds are physical, at the view's DPI.
inline PixelRect ToPhysical(double x, double y, double width, double height,
                            double scale) {
  if (!(scale > 0)) scale = 1;
  if (!(width > 0) || !(height > 0)) return PixelRect{};
  PixelRect rect;
  rect.left = std::lround(x * scale);
  rect.top = std::lround(y * scale);
  rect.right = std::lround((x + width) * scale);
  rect.bottom = std::lround((y + height) * scale);
  return rect;
}

constexpr const wchar_t* kYoutubeHostOrigin = L"https://top.npcserver.slimm/";

inline bool StartsWith(const std::wstring& text, const wchar_t* prefix) {
  return text.compare(0, std::wstring(prefix).size(), prefix) == 0;
}

// The host page itself, which the view may show; any other top-level page opens in the browser.
inline bool IsYoutubeHostUrl(const std::wstring& url) {
  return StartsWith(url, kYoutubeHostOrigin);
}

// Only a secure web link is handed to the browser, never plain http, a file or a custom scheme.
inline bool IsWebUrl(const std::wstring& url) {
  return StartsWith(url, L"https://");
}

}  // namespace slimm

#endif  // RUNNER_YOUTUBE_PLAYER_GEOMETRY_H_
