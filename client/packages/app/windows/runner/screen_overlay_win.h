#ifndef RUNNER_SCREEN_OVERLAY_WIN_H_
#define RUNNER_SCREEN_OVERLAY_WIN_H_

#include <cstdint>
#include <string>
#include <vector>

// The click-through, always-on-top, transparent window that shows a sharer's
// own screen what viewers drew on it, hidden from screen capture so it never
// lands in the share. docs/decisions/0096-screen-overlay.md says why.

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
  // Normalised to the monitor: x, y pairs for a stroke, x0 y0 x1 y1 for an
  // ellipse, x y for a note.
  std::vector<double> points;
  double width = 4;
  uint32_t argb = 0xFFFF0000;
  double alpha = 1;
  std::wstring text;
};

// False when this Windows cannot exclude a window from capture (before
// Windows 10 version 2004), because an overlay that lands in the share is
// worse than none.
bool Supported(std::vector<Monitor>* monitors);

// Opens the overlay over monitor index [monitor]; false when it could not be
// made or could not be hidden from capture.
bool Show(int monitor);

void Draw(std::vector<Shape> shapes);

void Hide();

}  // namespace slimm_overlay

#endif  // RUNNER_SCREEN_OVERLAY_WIN_H_
