// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a dropped item really is, for plugins that report every drop as a file.
library;

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';

/// Whether [item] is a folder, even when the plugin handed it over as a file.
///
/// The Linux plugin never builds a directory item, so the path itself is checked.
bool isDroppedFolder(DropItem item) {
  if (item is DropItemDirectory) return true;
  if (kIsWeb) return false;
  try {
    return FileSystemEntity.isDirectorySync(item.path);
  } on FileSystemException {
    return false;
  }
}

/// Whether [item] names something other than a local file, such as a web address.
bool isDroppedAddress(DropItem item) => item.path.contains('://');
