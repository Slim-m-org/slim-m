#ifndef RUNNER_SCREEN_OVERLAY_WIN_CAPTURE_H_
#define RUNNER_SCREEN_OVERLAY_WIN_CAPTURE_H_

#include <vector>

#include "screen_overlay_win.h"

namespace slimm_overlay {

/// Fills device_index and capture_position the way libwebrtc numbers screens, so
/// a shared "Screen N" or source id can be turned back into a monitor. With
/// DirectX capture the order is the DXGI outputs attached to the desktop, adapter
/// by adapter (dxgi_duplicator_controller.cc, dxgi_adapter_duplicator.cc,
/// d3d_device.cc); when DXGI lists nothing it is the active display devices
/// (screen_capture_utils.cc). The source id is the EnumDisplayDevices index of
/// the device in both cases (screen_capturer_win_directx.cc).
void AssignCaptureOrder(std::vector<Monitor>* monitors);

}  // namespace slimm_overlay

#endif  // RUNNER_SCREEN_OVERLAY_WIN_CAPTURE_H_
