#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// Passed by a restart, so the new copy waits for the old one to exit instead
// of handing focus to an instance that is about to quit. Matches relaunch.dart.
constexpr wchar_t kRelaunchArgument[] = L"--relaunch";

// Claims this session's single instance. Returns false when another copy
// already runs: it has been asked to come forward, and this one should exit.
bool ClaimSingleInstance(const wchar_t* command_line);

// The window message a second launch broadcasts to the running copy.
UINT SecondInstanceMessage();

// Registers the channel that tells Dart a second launch asked for focus; the
// same channel and `focus` call the Linux runner sends.
void RegisterSecondInstanceChannel(flutter::BinaryMessenger* messenger);

// Brings `window` forward and tells Dart, for a SecondInstanceMessage.
void OnSecondInstance(HWND window);

#endif  // RUNNER_SINGLE_INSTANCE_H_
