// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef SLIMM_LINUX_SCREEN_OVERLAY_H_
#define SLIMM_LINUX_SCREEN_OVERLAY_H_

#include <cstdint>
#include <string>
#include <vector>

// The click-through, always-on-top, transparent window that shows a sharer's own screen what viewers drew on it. Decision 0096 says why it is a native window and how each desktop is handled.

namespace slimm_overlay {

struct Monitor {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  bool primary = false;
};

struct Shape {
  enum class Kind { kStroke, kEllipse, kNote };
  Kind kind = Kind::kStroke;
  // Normalised to the monitor: x, y pairs for a stroke, x0 y0 x1 y1 for an ellipse, x y for a note.
  std::vector<double> points;
  double width = 4;
  uint32_t argb = 0xFFFF0000;
  double alpha = 1;
  std::string text;
};

// What the desktop can host: false with no monitors where it cannot, so Dart never offers the setting.
bool Supported(std::vector<Monitor>* monitors);

// Opens the overlay over monitor index [monitor]; false when it could not be made.
bool Show(int monitor);

void Draw(std::vector<Shape> shapes);

void Hide();

}  // namespace slimm_overlay

#endif  // SLIMM_LINUX_SCREEN_OVERLAY_H_
