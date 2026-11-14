#ifndef RUNNER_WINDOWS_TOASTS_CHANNEL_H_
#define RUNNER_WINDOWS_TOASTS_CHANNEL_H_

#include <flutter/binary_messenger.h>

// Serves `slimm/windows_toasts`: removes one toast this app posted, which the notification plugin cannot do unpackaged.
void RegisterWindowsToastsChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_WINDOWS_TOASTS_CHANNEL_H_
