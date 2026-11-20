// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_GEOMETRY_H_
#define RUNNER_YOUTUBE_PLAYER_GEOMETRY_H_

#include <cstdlib>
#include <string>

/// The YouTube player's pure rules, kept free of Windows headers so
/// test/runner_logic_test.cpp can run them anywhere.
namespace slimm {

/// One press of the primary button: when, and where in physical pixels.
struct Click {
  unsigned long long time_ms = 0;
  long x = 0;
  long y = 0;
};

// Two presses make a double click within the system's time and distance; a cleared [previous] never does.
inline bool IsDoubleClick(const Click& previous, const Click& now,
                          unsigned long long max_ms, long max_dx, long max_dy) {
  if (previous.time_ms == 0 || now.time_ms < previous.time_ms) return false;
  return now.time_ms - previous.time_ms <= max_ms &&
         std::labs(now.x - previous.x) <= max_dx / 2 &&
         std::labs(now.y - previous.y) <= max_dy / 2;
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
