// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one line a command row carries about the module behind it. Plain Dart,
/// so the composer's autocomplete vocabulary can use it without Flutter.
library;

import 'package:slimm_api/api.dart' as api;

/// "uses the internet" and the module's name beside a command's description,
/// so the row says who provides it.
String moduleCommandDetail(String? description, api.ModuleInfo? module) {
  final parts = [
    if (description != null && description.isNotEmpty) description,
    if (module != null) module.name,
    if (module != null && module.reachesNetwork) 'uses the internet',
  ];
  return parts.join(' · ');
}
