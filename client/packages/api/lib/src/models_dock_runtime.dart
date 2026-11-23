// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A Dock module's artifact and the runtime it names. Split out of
/// models_dock.dart to stay under the line budget.
library;

/// Where a module's verified artifact lives, and the hash the install call
/// checks it against before anything runs.
class DockArtifact {
  const DockArtifact({
    required this.kind,
    required this.path,
    required this.sha256,
  });

  final String kind;
  final String path;

  /// 64 lowercase hex characters.
  final String sha256;

  factory DockArtifact.fromJson(Map<String, dynamic> json) => DockArtifact(
        kind: json['kind'] as String,
        path: json['path'] as String,
        sha256: json['sha256'] as String,
      );
}

/// Resource ceilings the host enforces on a module's runtime. Any field can
/// be absent, meaning that backend applies its own default rather than the
/// manifest naming one.
class DockLimits {
  const DockLimits({this.memoryMb, this.wallMs, this.fuel});

  final int? memoryMb;
  final int? wallMs;

  /// The WASM fuel budget metering CPU use; see decision 0021's runtime
  /// section for why this replaces a wall-clock-only limit.
  final int? fuel;

  factory DockLimits.fromJson(Map<String, dynamic> json) => DockLimits(
        memoryMb: json['memory_mb'] as int?,
        wallMs: json['wall_ms'] as int?,
        fuel: json['fuel'] as int?,
      );
}

/// Which host-provided runtime a module needs, and its resource ceilings. A
/// module never ships or installs a runtime; it only names one slim already
/// offers.
class DockRuntime {
  const DockRuntime({required this.backend, required this.limits});

  final String backend;
  final DockLimits limits;

  factory DockRuntime.fromJson(Map<String, dynamic> json) => DockRuntime(
        backend: json['backend'] as String,
        limits: DockLimits.fromJson(json['limits'] as Map<String, dynamic>),
      );
}
