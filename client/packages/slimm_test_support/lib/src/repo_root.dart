// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a source-reading or fixture-reading test finds the repository.
library;

import 'dart:io';

/// The repository root, found by walking up from [from] (default: the working
/// directory) to the first directory holding `schema/openapi.yaml`.
Directory findRepoRoot([Directory? from]) {
  final start = (from ?? Directory.current).absolute;
  var dir = start;
  while (!File('${dir.path}/schema/openapi.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('could not find the repo root above ${start.path}');
    }
    dir = parent;
  }
  return dir;
}
