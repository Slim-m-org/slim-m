#ifndef RUNNER_SCREEN_OVERLAY_WIN_PNG_H_
#define RUNNER_SCREEN_OVERLAY_WIN_PNG_H_

#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <vector>

// gdiplus.h needs the min and max macros the runner turns off.
using std::max;
using std::min;
#include <gdiplus.h>

namespace slimm_overlay {

// Starts GDI+ once for the process; false when it will not start.
bool EnsureGdiplus();

// A premultiplied bitmap decoded from PNG bytes the app made, or nullptr when they do not decode; GDI+ must be running.
std::unique_ptr<Gdiplus::Bitmap> DecodePicture(const std::vector<uint8_t>& png);

}  // namespace slimm_overlay

#endif  // RUNNER_SCREEN_OVERLAY_WIN_PNG_H_
