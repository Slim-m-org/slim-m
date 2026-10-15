// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A minimal module manifest body for the Dock tests that need one fetched.
library;

/// The manifest `GET /space/dock/modules/{id}` answers for [id] at [version],
/// asking the host for [capabilities].
Map<String, dynamic> dockManifestJson(
  String id,
  String version, {
  List<String> capabilities = const [],
  Map<String, dynamic>? network,
  List<Map<String, dynamic>>? schedules,
}) => {
  'id': id,
  'name': id,
  'version': version,
  'summary': 'does something',
  'artifact': {
    'kind': 'wasm',
    'path': 'modules/$id/$version/module.wasm',
    'sha256': List.filled(64, 'a').join(),
  },
  'runtime': {
    'backend': 'wasm',
    'limits': {'memory_mb': 32, 'wall_ms': 1000, 'fuel': 100000000},
  },
  'permissions': <Map<String, dynamic>>[],
  'capabilities': capabilities,
  'extension_points': <Map<String, dynamic>>[],
  'network': ?network,
  'schedules': ?schedules,
};
