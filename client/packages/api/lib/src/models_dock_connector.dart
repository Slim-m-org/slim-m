// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A connector (decision 0090): a module whose logic is an external program
/// holding a bot token scoped to the permissions an admin approved.
library;

/// The core permission bits a manifest's connector asks for, or null for a WASM module.
int? dockConnectorAsk(Map<String, dynamic> manifest) {
  if (manifest['provider'] != 'connector') return null;
  final connector = manifest['connector'];
  if (connector is! Map<String, dynamic>) return null;
  return connector['permissions'] as int?;
}

/// What a connector reads about itself with its own token (`GET /connectors/me`).
class ConnectorSelf {
  const ConnectorSelf({
    required this.moduleId,
    required this.name,
    required this.version,
    required this.permissions,
    required this.settings,
  });

  final String moduleId;
  final String name;
  final String version;

  /// The ceiling on its token, as the admin approved it.
  final int permissions;

  /// Every declared setting by key, secrets in plain text; null when unset.
  final Map<String, Object?> settings;

  factory ConnectorSelf.fromJson(Map<String, dynamic> json) => ConnectorSelf(
        moduleId: json['module_id'] as String,
        name: json['name'] as String,
        version: json['version'] as String,
        permissions: json['permissions'] as int,
        settings: Map<String, Object?>.from(json['settings'] as Map),
      );
}
