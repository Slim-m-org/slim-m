// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Readers for the module platform fields a manifest and an installed module
/// carry, per `docs/decisions/0091-module-platform-phase-1-contracts.md`.
library;

/// The event kinds a module subscribes to, from names or `{event: name}`.
List<String> dockSubscriptions(Object? json) {
  if (json is! List) return const [];
  return [
    for (final entry in json)
      if (entry is String)
        entry
      else if (entry is Map && entry['event'] is String)
        entry['event'] as String,
  ];
}

/// The size cap in MB of the data store a module declares, or null when it
/// declares none. The host's default applies when `max_mb` is left out.
int? dockDataMaxMb(Object? json) {
  if (json is! Map) return null;
  final mb = json['max_mb'];
  return mb is int ? mb : 8;
}

/// Whether a module's `settings` array declares at least one setting.
bool dockDeclaresSettings(Object? json) => json is List && json.isNotEmpty;
