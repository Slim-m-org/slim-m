// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How much the server logs, and the lines an admin downloads (decision 0129).
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

/// The newest server log lines, as `GET /space/server-logs` returns them.
class ServerLogs {
  const ServerLogs({
    required this.log,
    required this.truncated,
    required this.filesEnabled,
  });

  /// Oldest line first.
  final String log;

  /// Older lines exist than fit in one download.
  final bool truncated;

  /// False when the server writes no log files, so [log] is empty.
  final bool filesEnabled;

  factory ServerLogs.fromJson(Map<String, dynamic> json) => ServerLogs(
        log: json['log'] as String? ?? '',
        truncated: json['truncated'] as bool? ?? false,
        filesEnabled: json['files_enabled'] as bool? ?? false,
      );
}
