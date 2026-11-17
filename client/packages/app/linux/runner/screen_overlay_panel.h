// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef SLIMM_LINUX_SCREEN_OVERLAY_PANEL_H_
#define SLIMM_LINUX_SCREEN_OVERLAY_PANEL_H_

#include <cairo.h>

#include "screen_overlay.h"

namespace slimm_overlay {

// Decodes the pictures a panel carries into the cache, keyed by user id, and drops the bytes.
void CacheAvatars(Panel* panel);

// Empties the picture cache, once the window it served is gone.
void ForgetAvatars();

// The part of a surface the panel may sit in: the monitor's work area, clear of panels and docks.
struct Area {
  double x = 0;
  double y = 0;
  double w = 0;
  double h = 0;
};

// Paints the call panel into its corner of [area].
void DrawPanel(cairo_t* cr, const Panel& panel, const Area& area);

}  // namespace slimm_overlay

#endif  // SLIMM_LINUX_SCREEN_OVERLAY_PANEL_H_
