#ifndef RUNNER_LAUNCHER_HANDOFF_H_
#define RUNNER_LAUNCHER_HANDOFF_H_

/// Starts the per-user launcher with this start's arguments when this copy
/// should have come through it (LauncherToHandTo); true means it did and this
/// process should exit. Clears the launcher's marker either way, so nothing
/// this app starts inherits it.
bool HandStartToLauncher(const wchar_t* command_line);

#endif  // RUNNER_LAUNCHER_HANDOFF_H_
