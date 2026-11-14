#include "toast_history_win.h"

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.h>

using winrt::Windows::UI::Notifications::ToastNotificationManager;

// The notification plugin can only remove by tag with package identity; an unpackaged app has to name its AUMID and the toast's own group.
bool RemoveToast(const std::wstring& tag, const std::wstring& aumid) {
  try {
    const auto history = ToastNotificationManager::History();
    for (const auto& toast : history.GetHistory(aumid)) {
      if (toast.Tag() == tag) {
        history.Remove(tag, toast.Group(), aumid);
        return true;
      }
    }
  } catch (const winrt::hresult_error&) {
  }
  return false;
}
