#include "screen_overlay_win_capture.h"

#include <windows.h>

#include <dxgi.h>

#include <wchar.h>

#include <string>

namespace slimm_overlay {
namespace {

bool SameDevice(const std::wstring& a, const std::wstring& b) {
  return _wcsicmp(a.c_str(), b.c_str()) == 0;
}

int IndexOf(const std::vector<std::wstring>& names, const std::wstring& device) {
  for (size_t i = 0; i < names.size(); i++) {
    if (SameDevice(names[i], device)) return static_cast<int>(i);
  }
  return -1;
}

bool IsValidRect(const RECT& r) { return r.right > r.left && r.bottom > r.top; }

void CollectOutputs(IDXGIAdapter* adapter, std::vector<std::wstring>* names) {
  for (UINT o = 0;; o++) {
    IDXGIOutput* output = nullptr;
    HRESULT result = adapter->EnumOutputs(o, &output);
    if (result == DXGI_ERROR_NOT_FOUND ||
        result == DXGI_ERROR_NOT_CURRENTLY_AVAILABLE) {
      break;
    }
    if (FAILED(result) || output == nullptr) continue;
    DXGI_OUTPUT_DESC desc = {};
    if (SUCCEEDED(output->GetDesc(&desc)) && desc.AttachedToDesktop &&
        IsValidRect(desc.DesktopCoordinates)) {
      names->push_back(desc.DeviceName);
    }
    output->Release();
  }
}

std::vector<std::wstring> DxgiOutputNames() {
  std::vector<std::wstring> names;
  IDXGIFactory1* factory = nullptr;
  if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1),
                                reinterpret_cast<void**>(&factory))) ||
      factory == nullptr) {
    return names;
  }
  for (UINT a = 0;; a++) {
    IDXGIAdapter* adapter = nullptr;
    if (FAILED(factory->EnumAdapters(a, &adapter)) || adapter == nullptr) break;
    CollectOutputs(adapter, &names);
    adapter->Release();
  }
  factory->Release();
  return names;
}

// Every display device by its EnumDisplayDevices index, with whether it is active; names are empty past the last device.
struct DisplayDevices {
  std::vector<std::wstring> names;
  std::vector<bool> active;
};

DisplayDevices EnumerateDevices() {
  DisplayDevices out;
  for (DWORD i = 0;; i++) {
    DISPLAY_DEVICEW device = {};
    device.cb = sizeof(device);
    if (!EnumDisplayDevicesW(nullptr, i, &device, 0)) break;
    out.names.push_back(device.DeviceName);
    out.active.push_back((device.StateFlags & DISPLAY_DEVICE_ACTIVE) != 0);
  }
  return out;
}

}  // namespace

void AssignCaptureOrder(std::vector<Monitor>* monitors) {
  DisplayDevices devices = EnumerateDevices();
  std::vector<std::wstring> dxgi = DxgiOutputNames();
  std::vector<std::wstring> active;
  for (size_t i = 0; i < devices.names.size(); i++) {
    if (devices.active[i]) active.push_back(devices.names[i]);
  }
  const std::vector<std::wstring>& order = dxgi.empty() ? active : dxgi;
  for (Monitor& m : *monitors) {
    m.device_index = IndexOf(devices.names, m.device);
    m.capture_position = IndexOf(order, m.device);
  }
}

}  // namespace slimm_overlay
