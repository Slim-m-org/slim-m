// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Extension filters for the native file pickers.
library;

import 'package:flutter/foundation.dart';

/// [extensions] for `allowedExtensions`, with upper-case twins on Linux.
///
/// GTK portals turn each into a case-sensitive glob, so `IMG_0001.JPG` would not match `*.jpg`.
List<String> pickerExtensions(
  List<String> extensions, {
  TargetPlatform? platform,
}) {
  if ((platform ?? defaultTargetPlatform) != TargetPlatform.linux) {
    return extensions;
  }
  return [
    for (final e in extensions) ...[
      e,
      if (e != e.toUpperCase()) e.toUpperCase(),
    ],
  ];
}
