// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_MAIN_WINDOW_H_
#define RUNNER_MAIN_WINDOW_H_

#include <flutter/flutter_engine.h>

/// Serves `top.npcserver.slimm/main_window`'s `ready`, which Dart calls once it
/// has created the main window: every plugin and runner channel is registered
/// then, because several of them look the window up when they are registered.
void ServeMainWindowReady(flutter::FlutterEngine* engine);

/// Destroys every window Dart created while Dart can still hear it go; the
/// engine's own shutdown teardown would otherwise message a stopped isolate.
void DestroyDartWindows();

#endif  // RUNNER_MAIN_WINDOW_H_
