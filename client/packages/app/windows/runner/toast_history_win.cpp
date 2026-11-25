#include "toast_history_win.h"

#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.h>

#include <vector>

using winrt::Windows::UI::Notifications::ToastNotification;
using winrt::Windows::UI::Notifications::ToastNotificationHistory;
using winrt::Windows::UI::Notifications::ToastNotificationManager;

namespace {

bool HasToast(const ToastNotificationHistory& history, const std::wstring& tag,
              const std::wstring& aumid, std::wstring* group) {
  for (const auto& toast : history.GetHistory(aumid)) {
    if (toast.Tag() != tag) continue;
    if (group != nullptr) *group = toast.Group().c_str();
    return true;
  }
  return false;
}

// Per-toast failures are skipped so one toast that will not come back cannot cost the others theirs.
void RestoreSilently(const std::vector<ToastNotification>& toasts, const std::wstring& aumid) {
  const auto notifier = ToastNotificationManager::CreateToastNotifier(aumid);
  for (const auto& toast : toasts) {
    try {
      ToastNotification copy(toast.Content());
      copy.Tag(toast.Tag());
      if (!toast.Group().empty()) copy.Group(toast.Group());
      copy.SuppressPopup(true);
      notifier.Show(copy);
    } catch (const winrt::hresult_error&) {
    }
  }
}

}  // namespace

bool RemoveToast(const std::wstring& tag, const std::wstring& aumid) {
  try {
    const auto history = ToastNotificationManager::History();
    std::wstring group;
    if (!HasToast(history, tag, aumid, &group)) return false;
    // Windows rejects an empty group, so only a grouped toast can be removed on its own.
    if (!group.empty()) {
      try {
        history.Remove(tag, group, aumid);
        if (!HasToast(history, tag, aumid, nullptr)) return true;
      } catch (const winrt::hresult_error&) {
      }
    }
    std::vector<ToastNotification> others;
    for (const auto& toast : history.GetHistory(aumid)) {
      if (toast.Tag() != tag) others.push_back(toast);
    }
    history.Clear(aumid);
    RestoreSilently(others, aumid);
    return true;
  } catch (const winrt::hresult_error&) {
    return false;
  }
}
