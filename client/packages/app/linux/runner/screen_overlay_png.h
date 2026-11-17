// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef SLIMM_LINUX_SCREEN_OVERLAY_PNG_H_
#define SLIMM_LINUX_SCREEN_OVERLAY_PNG_H_

#include <cairo.h>

#include <cstdint>
#include <vector>

namespace slimm_overlay {

// A surface decoded from PNG bytes the app made, or nullptr when they do not decode.
cairo_surface_t* DecodePng(const std::vector<uint8_t>& png);

}  // namespace slimm_overlay

#endif  // SLIMM_LINUX_SCREEN_OVERLAY_PNG_H_
