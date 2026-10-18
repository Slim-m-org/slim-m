// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the Dock shows about an installed module beyond its manifest: how its
/// commands have run, how much it has stored, and who it is to the members who
/// meet its commands. Split out of models_dock.dart to stay under the line
/// budget.
library;

/// How one command of an installed module has run lately, from
/// `GET /space/dock/installed`.
class DockRunStat {
  const DockRunStat({
    required this.command,
    required this.runCount,
    required this.failureCount,
    required this.lastRunAt,
    required this.lastDurationMs,
    required this.maxDurationMs,
    this.lastOkAt,
    this.failingSince,
    this.lastError,
    this.lastErrorAt,
  });

  final String command;
  final int runCount;
  final int failureCount;

  /// Unix milliseconds.
  final int lastRunAt;
  final int? lastOkAt;

  /// When the current run of failures began; null while the last run worked.
  final int? failingSince;
  final String? lastError;
  final int? lastErrorAt;
  final int lastDurationMs;
  final int maxDurationMs;

  factory DockRunStat.fromJson(Map<String, dynamic> json) => DockRunStat(
        command: json['command'] as String,
        runCount: json['run_count'] as int,
        failureCount: json['failure_count'] as int,
        lastRunAt: json['last_run_at'] as int,
        lastOkAt: json['last_ok_at'] as int?,
        failingSince: json['failing_since'] as int?,
        lastError: json['last_error'] as String?,
        lastErrorAt: json['last_error_at'] as int?,
        lastDurationMs: json['last_duration_ms'] as int,
        maxDurationMs: json['max_duration_ms'] as int,
      );
}

/// What a module's `kv.store` holds against its allowance.
class DockStorage {
  const DockStorage({
    required this.entries,
    required this.bytes,
    required this.maxEntries,
    required this.maxBytes,
  });

  final int entries;

  /// Keys plus values.
  final int bytes;
  final int maxEntries;
  final int maxBytes;

  factory DockStorage.fromJson(Map<String, dynamic> json) => DockStorage(
        entries: json['entries'] as int,
        bytes: json['bytes'] as int,
        maxEntries: json['max_entries'] as int,
        maxBytes: json['max_bytes'] as int,
      );
}

/// Which module provides a command and what an admin let it do, so a member
/// can tell a third-party module from a built-in feature.
class ModuleInfo {
  const ModuleInfo({
    required this.name,
    required this.verified,
    this.capabilities = const [],
    this.networkHosts = const [],
  });

  final String name;

  /// True for a module from the official registry.
  final bool verified;

  /// Approved host capabilities: `kv.store`, `message.post`, `net.fetch`,
  /// `schedule`.
  final List<String> capabilities;

  /// The sites `net.fetch` may reach.
  final List<String> networkHosts;

  bool get reachesNetwork => capabilities.contains('net.fetch');
  bool get posts => capabilities.contains('message.post');
  bool get runsOnItsOwn => capabilities.contains('schedule');

  static ModuleInfo? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    List<String> strings(Object? list) => [
          for (final item in (list as List<dynamic>?) ?? const [])
            if (item is String) item,
        ];
    return ModuleInfo(
      name: json['name'] as String,
      verified: json['verified'] as bool? ?? false,
      capabilities: strings(json['capabilities']),
      networkHosts: strings(json['network_hosts']),
    );
  }
}
