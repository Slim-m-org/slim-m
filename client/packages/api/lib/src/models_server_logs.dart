// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How much the server logs (decision 0129).
library;

/// The space's server log mode.
enum ServerLogMode {
  /// Warnings, errors and lifecycle events only.
  off,

  /// One debug line per event from the subsystems bugs are hunted in.
  compact,

  /// Every debug and trace line the server writes.
  verbose;

  String get wire => name;

  /// An unknown or missing mode reads as [off].
  static ServerLogMode parse(String? value) => switch (value) {
        'compact' => compact,
        'verbose' => verbose,
        _ => off,
      };
}
