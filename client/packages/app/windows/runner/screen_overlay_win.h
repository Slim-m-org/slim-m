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
  // GDI device name, such as \\.\DISPLAY1; what the capture order is matched on.
  std::wstring device;
  // libwebrtc's screen id for this monitor, or -1 when it is not an active display device.
  int device_index = -1;
  // This monitor's 0-based place in libwebrtc's "Screen N" order, or -1 when unknown.
  int capture_position = -1;
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
  std::string id;
  std::wstring name;
  bool speaking = false;
  bool muted = false;
  bool deafened = false;
  // A round PNG for this id, sent once per picture; empty when the runner already holds it.
  std::vector<uint8_t> avatar;
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

// Opens the drawing overlay over monitor index [monitor]; false when it could
// not be made or could not be hidden from capture. The call panel keeps its own
// window, so showing or hiding this one never touches it.
bool Show(int monitor);

void Draw(std::vector<Shape> shapes);

// Closes the drawing overlay.
void Hide();

// Paints the panel in its own overlay window over the panel's monitor; a panel that is not present closes that window.
void SetPanel(Panel panel);

// The index of the monitor the app's own window is on, or -1 when that cannot be told.
int AppMonitor();

}  // namespace slimm_overlay

#endif  // RUNNER_SCREEN_OVERLAY_WIN_H_
