#ifndef RUNNER_SCREEN_OVERLAY_WIN_PANEL_H_
#define RUNNER_SCREEN_OVERLAY_WIN_PANEL_H_

#include <windows.h>

#include <algorithm>

// gdiplus.h needs the min and max macros the runner turns off.
using std::max;
using std::min;
#include <gdiplus.h>

#include "screen_overlay_win.h"

namespace slimm_overlay {

// Decodes the pictures a panel carries into the cache, keyed by user id, and drops the bytes; GDI+ must be running.
void CacheAvatars(Panel* panel);

// Empties the picture cache, once the window it served is gone.
void ForgetAvatars();

// Paints the call panel into its corner of a width by height surface; [scale] is the window's DPI over 96.
void DrawPanel(Gdiplus::Graphics& g, const Panel& panel, double width,
               double height, double scale);

}  // namespace slimm_overlay

#endif  // RUNNER_SCREEN_OVERLAY_WIN_PANEL_H_
