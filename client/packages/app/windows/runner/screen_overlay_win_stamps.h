#ifndef RUNNER_SCREEN_OVERLAY_WIN_STAMPS_H_
#define RUNNER_SCREEN_OVERLAY_WIN_STAMPS_H_

#include "screen_overlay_win_png.h"
#include "screen_overlay_win.h"

// The pictures stamps are drawn from (decision 0121): the app bakes each one to a PNG and sends it once under a key, and a draw frame names the key.

namespace slimm_overlay {

// Paints one stamp shape into a width by height surface, in device pixels; one whose picture is not held draws nothing.
void DrawStamp(Gdiplus::Graphics& g, const Shape& s, double width, double height);

}  // namespace slimm_overlay

#endif  // RUNNER_SCREEN_OVERLAY_WIN_STAMPS_H_
