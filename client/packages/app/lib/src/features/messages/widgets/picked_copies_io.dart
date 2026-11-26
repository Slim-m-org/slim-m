// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Deletes the copies `image_picker` makes of a pick.
library;

import 'dart:io';

/// Removes each pick's own folder, only when it sits directly in [tempRoot].
///
/// `image_picker` copies a pick to `<cache>/<uuid>/<name>` and has no call to clear it.
Future<void> deletePickedCopies(Iterable<String> paths, String tempRoot) async {
  final root = Directory(tempRoot).absolute.path;
  for (final path in paths) {
    final folder = File(path).absolute.parent;
    if (folder.parent.path != root) continue;
    if (await folder.exists()) await folder.delete(recursive: true);
  }
}
