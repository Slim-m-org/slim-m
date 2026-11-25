#ifndef RUNNER_SESSION_LOCK_CHANNEL_H_
#define RUNNER_SESSION_LOCK_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// Serves `slimm/session_lock`: tells Dart when the session locks, disconnects or the machine suspends (`away`), and when it returns (`back`).
void RegisterSessionLockChannel(flutter::BinaryMessenger* messenger,
                                HWND window);

// Forwards a window message of the main window; never consumes it.
void OnSessionLockMessage(UINT message, WPARAM wparam);

// Stops the session notifications before the window goes.
void UnregisterSessionLockChannel();

#endif  // RUNNER_SESSION_LOCK_CHANNEL_H_
