#ifndef RUNNER_TOAST_HISTORY_WIN_H_
#define RUNNER_TOAST_HISTORY_WIN_H_

#include <string>

// Takes down the toast tagged `tag` that `aumid` posted, on screen and in the notification centre; false if none was found.
bool RemoveToast(const std::wstring& tag, const std::wstring& aumid);

#endif  // RUNNER_TOAST_HISTORY_WIN_H_
