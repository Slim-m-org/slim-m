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

struct PanelRow {
  std::wstring name;
  bool speaking = false;
  bool muted = false;
  bool deafened = false;
};

// The call panel: one row per person, in one corner of one monitor.
struct Panel {
  bool present = false;
  int monitor = 0;
  enum class Corner { kTopLeft, kTopRight, kBottomLeft, kBottomRight };
  Corner corner = Corner::kTopLeft;
  std::vector<PanelRow> rows;
  int more = 0;
  uint32_t surface = 0xE01F2226;
  uint32_t border = 0xFF2E333A;
  uint32_t text = 0xFFECEDEF;
  uint32_t text_muted = 0xFFA7AEB6;
  uint32_t accent = 0xFF58B4D8;
  uint32_t danger = 0xFFD4756B;
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

// Paints the panel on the overlay window when it is over the panel's monitor; a panel that is not present clears it.
void SetPanel(Panel panel);

// The index of the monitor the app's own window is on, or -1 when that cannot be told.
int AppMonitor();

}  // namespace slimm_overlay

#endif  // RUNNER_SCREEN_OVERLAY_WIN_H_
