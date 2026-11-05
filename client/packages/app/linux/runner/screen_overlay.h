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

struct PanelRow {
  std::string name;
  bool speaking = false;
  bool muted = false;
  bool deafened = false;
};

// The call panel: one row per person, in one corner of one monitor (an index into Supported's list).
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

// What the desktop can host: false with no monitors where it cannot, so Dart never offers the setting.
bool Supported(std::vector<Monitor>* monitors);

// Opens the overlay over every listed monitor index; false when it could not be made.
bool Show(const std::vector<int>& monitors);

void Draw(std::vector<Shape> shapes);

void Hide();

// Paints the panel on the overlay window of its monitor; a panel that is not present clears it.
void SetPanel(Panel panel);

// The index of the monitor the app's own window is on, or -1 when that cannot be told.
int AppMonitor();

}  // namespace slimm_overlay

#endif  // SLIMM_LINUX_SCREEN_OVERLAY_H_
