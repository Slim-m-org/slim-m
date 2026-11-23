// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_POPOUT_WINDOW_PROC_H_
#define RUNNER_POPOUT_WINDOW_PROC_H_

#include <windows.h>

#include <optional>

/// Takes, for a pop-out window, the messages window_manager would otherwise
/// treat as the main window's: it hears every top-level window and keeps one
/// global state, so it would strip the pop-out's frame, impose the main
/// window's minimum size and report the pop-out's focus and size as the main
/// window's. Each is answered as the engine's own window would answer it.
std::optional<LRESULT> HandlePopOutMessage(HWND window, UINT message,
                                           WPARAM wparam, LPARAM lparam);

#endif  // RUNNER_POPOUT_WINDOW_PROC_H_
