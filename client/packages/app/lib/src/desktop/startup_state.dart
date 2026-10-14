// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The three pieces of state the startup screen renders from, in a file of
/// their own rather than in `main.dart`: `startup_updates.dart` writes all
/// three during the splash, and a `src/` file importing the entry point to
/// reach them would be backwards. `main.dart` re-exports them, so a test
/// that already reads them from there still can.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'startup_screen.dart';

/// Whether `_bootstrapApp` has finished. Defaults to true rather than false:
/// a test pumping `SlimMApp()` directly, with no call ever made into
/// `_bootstrapApp`, sees the real app immediately, matching every existing
/// test's assumption - only the real entry point above ever sets it false
/// first.
final appReadyProvider = StateProvider<bool>((ref) => true);

/// The startup screen's status line, updated at each phase boundary in
/// `_runBootstrapSequence`. Deliberately plain text today rather than an enum
/// of phases: the structure this exists for is the provider itself, so a
/// later update flow ("Checking for updates", "Downloading update",
/// "Installing update") is copy at the call sites above, not new plumbing.
final startupStatusProvider = StateProvider<String>(
  (ref) => defaultStartupStatus,
);

/// The question the splash is putting to the user while `runStartupUpdates`
/// waits on it, or null when it is not asking anything. The splash renders
/// the buttons; their callbacks resolve the wait. See decision 0025.
final startupPromptProvider = StateProvider<StartupPrompt?>((ref) => null);

/// True for the splash's last moment, while its content fades out ahead of
/// the window hiding for the handoff, so it leaves instead of vanishing.
final startupLeavingProvider = StateProvider<bool>((ref) => false);
