#include "taskbar_attention_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <cstdint>
#include <memory>
#include <string>
#include <variant>

namespace {

using Microsoft::WRL::ComPtr;

constexpr int kIconSize = 16;
constexpr int kMaxShownCount = 9;

bool FlashTaskbarButton(HWND window, DWORD flags) {
  FLASHWINFO info = {sizeof(info), window, flags, 0, 0};
  return FlashWindowEx(&info) != FALSE || flags == FLASHW_STOP;
}

// A red disc with the count in white; GDI draws no alpha, so a mask bitmap cuts the corners.
HICON DrawBadge(int count) {
  HDC screen = GetDC(nullptr);
  HDC dc = CreateCompatibleDC(screen);
  HBITMAP color = CreateCompatibleBitmap(screen, kIconSize, kIconSize);
  HBITMAP mask = CreateBitmap(kIconSize, kIconSize, 1, 1, nullptr);
  ReleaseDC(nullptr, screen);

  const RECT bounds = {0, 0, kIconSize, kIconSize};
  HGDIOBJ previous = SelectObject(dc, mask);
  FillRect(dc, &bounds, static_cast<HBRUSH>(GetStockObject(WHITE_BRUSH)));
  SelectObject(dc, GetStockObject(BLACK_BRUSH));
  SelectObject(dc, GetStockObject(BLACK_PEN));
  Ellipse(dc, 0, 0, kIconSize, kIconSize);

  SelectObject(dc, color);
  HBRUSH red = CreateSolidBrush(RGB(0xD9, 0x2D, 0x20));
  SelectObject(dc, red);
  SelectObject(dc, GetStockObject(NULL_PEN));
  Ellipse(dc, 0, 0, kIconSize + 1, kIconSize + 1);

  const std::wstring text = count > kMaxShownCount
                                ? std::to_wstring(kMaxShownCount) + L"+"
                                : std::to_wstring(count);
  HFONT font = CreateFontW(-11, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
                           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
                           DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
  SelectObject(dc, font);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(255, 255, 255));
  RECT text_box = bounds;
  DrawTextW(dc, text.c_str(), -1, &text_box,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);

  SelectObject(dc, previous);
  DeleteObject(font);
  DeleteObject(red);
  DeleteDC(dc);

  ICONINFO icon_info = {TRUE, 0, 0, mask, color};
  HICON icon = CreateIconIndirect(&icon_info);
  DeleteObject(color);
  DeleteObject(mask);
  return icon;
}

class OverlayBadge {
 public:
  explicit OverlayBadge(HWND window) : window_(window) {}

  bool Set(int count) {
    count_ = count;
    if (!EnsureTaskbar()) return false;
    if (count <= 0) {
      return SUCCEEDED(taskbar_->SetOverlayIcon(window_, nullptr, nullptr));
    }
    HICON icon = DrawBadge(count);
    if (!icon) return false;
    const std::wstring label = std::to_wstring(count) + L" unread";
    const bool shown =
        SUCCEEDED(taskbar_->SetOverlayIcon(window_, icon, label.c_str()));
    DestroyIcon(icon);
    return shown;
  }

  // A new button means a new taskbar too, so the old interface is dropped first.
  void Reapply() {
    taskbar_.Reset();
    Set(count_);
  }

 private:
  bool EnsureTaskbar() {
    if (taskbar_) return true;
    if (FAILED(CoCreateInstance(__uuidof(TaskbarList), nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&taskbar_)))) {
      return false;
    }
    if (FAILED(taskbar_->HrInit())) {
      taskbar_.Reset();
      return false;
    }
    return true;
  }

  HWND window_;
  ComPtr<ITaskbarList3> taskbar_;
  int count_ = 0;
};

std::weak_ptr<OverlayBadge> g_badge;

}  // namespace

UINT TaskbarButtonCreatedMessage() {
  static const UINT message = RegisterWindowMessageW(L"TaskbarButtonCreated");
  return message;
}

void OnTaskbarButtonCreated() {
  if (auto badge = g_badge.lock()) badge->Reapply();
}

void RegisterTaskbarAttentionChannel(flutter::BinaryMessenger* messenger,
                                     HWND window) {
  auto channel =
      std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "slimm/taskbar_attention",
          &flutter::StandardMethodCodec::GetInstance());
  auto badge = std::make_shared<OverlayBadge>(window);
  g_badge = badge;
  channel->SetMethodCallHandler(
      [channel, badge, window](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        if (call.method_name() == "flash") {
          // TIMERNOFG ends the flash by itself once the window is focused.
          FlashTaskbarButton(window, FLASHW_TRAY | FLASHW_TIMERNOFG);
          result->Success();
        } else if (call.method_name() == "stop") {
          FlashTaskbarButton(window, FLASHW_STOP);
          result->Success();
        } else if (call.method_name() == "badge") {
          const auto* count = std::get_if<int32_t>(call.arguments());
          if (!count) {
            result->Error("bad_arguments", "badge takes the unread count");
            return;
          }
          badge->Set(*count);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}
