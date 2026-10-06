// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// File helpers every platform installer shares.
library;

import 'dart:io';

/// Deletes [entity] recursively; a locked or already-gone entry is left for the next cleanup pass.
void safeDelete(FileSystemEntity entity) {
  try {
    entity.deleteSync(recursive: true);
  } on FileSystemException {
    return;
  }
}
