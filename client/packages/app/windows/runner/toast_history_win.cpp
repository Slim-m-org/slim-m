#include "toast_history_win.h"

#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.h>

#include <vector>

using winrt::Windows::UI::Notifications::ToastNotification;
using winrt::Windows::UI::Notifications::ToastNotificationManager;

// An unpackaged app's toast is removable only by tag and group and the plugin sets no group, so all are cleared and the rest restored silently.
bool RemoveToast(const std::wstring& tag, const std::wstring& aumid) {
  try {
    const auto history = ToastNotificationManager::History();
    std::vector<ToastNotification> others;
    bool found = false;
    for (const auto& toast : history.GetHistory(aumid)) {
      if (toast.Tag() == tag) {
        found = true;
      } else {
        others.push_back(toast);
      }
    }
    if (!found) return false;
    history.Clear(aumid);
    const auto notifier = ToastNotificationManager::CreateToastNotifier(aumid);
    for (const auto& toast : others) {
      ToastNotification copy(toast.Content());
      copy.Tag(toast.Tag());
      if (!toast.Group().empty()) copy.Group(toast.Group());
      copy.SuppressPopup(true);
      notifier.Show(copy);
    }
    return true;
  } catch (const winrt::hresult_error&) {
    return false;
  }
}
