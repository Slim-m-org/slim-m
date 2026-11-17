// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef SLIMM_LINUX_SCREEN_OVERLAY_STAMPS_H_
#define SLIMM_LINUX_SCREEN_OVERLAY_STAMPS_H_

#include <cairo.h>

#include <cstdint>
#include <string>
#include <vector>

#include "screen_overlay.h"

// The pictures stamps are drawn from (decision 0121): the app bakes each one to a PNG and sends it once under a key, and a draw frame names the key.

namespace slimm_overlay {

// Holds [png] under [key], replacing any picture already there; false when it is too big or will not decode.
bool PutStampImage(const std::string& key, const std::vector<uint8_t>& png);

void DropStampImage(const std::string& key);

// Empties the cache, once the window it served is gone.
void ForgetStampImages();

// Paints one stamp shape into a w by h surface; one whose picture is not held draws nothing.
void DrawStamp(cairo_t* cr, const Shape& s, double w, double h);

}  // namespace slimm_overlay

#endif  // SLIMM_LINUX_SCREEN_OVERLAY_STAMPS_H_
