#ifndef RUNNER_TASKBAR_ATTENTION_CHANNEL_H_
#define RUNNER_TASKBAR_ATTENTION_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// Serves `slimm/taskbar_attention`: flash and stop the taskbar button, and badge it with an unread count.
void RegisterTaskbarAttentionChannel(flutter::BinaryMessenger* messenger,
                                     HWND window);

// The message Windows sends when the taskbar button is created or recreated, as after an Explorer restart.
UINT TaskbarButtonCreatedMessage();

// Puts the last unread badge back on a newly created taskbar button, which starts without one.
void OnTaskbarButtonCreated();

#endif  // RUNNER_TASKBAR_ATTENTION_CHANNEL_H_
