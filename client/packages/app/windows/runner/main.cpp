#include <flutter/dart_project.h>
#include <flutter/flutter_engine.h>
#include <windows.h>

#include <memory>

#include "app_identity.h"
#include "global_hotkeys_channel.h"
#include "launcher_handoff.h"
#include "link_scheme.h"
#include "main_window.h"
#include "single_instance.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  ClaimAppIdentity();
  if (ForwardLinkToRunningInstance()) {
    return EXIT_SUCCESS;
  }
  if (HandStartToLauncher(command_line)) {
    return EXIT_SUCCESS;
  }
  if (!ClaimSingleInstance(command_line)) {
    return EXIT_SUCCESS;
  }
  RegisterLinkScheme();

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  RepairShortcuts();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Dart creates every window, the main one included, as Flutter's windowing needs; see main_window.h.
  auto engine = std::make_shared<flutter::FlutterEngine>(project);
  ServeMainWindowReady(engine.get());
  if (!engine->Run()) {
    return EXIT_FAILURE;
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // window_manager quits with PostQuitMessage, so the windows are still alive here; tear them down while Dart still runs.
  UnregisterGlobalHotkeys();
  DestroyDartWindows();
  engine.reset();
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
