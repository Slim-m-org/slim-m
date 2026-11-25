// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Why a library photo is not worth downloading, decided from its size alone.
library;

import '../../../format.dart';

/// The sentence to show when [bytes] is over the server's [limit], else null.
String? oversizeNote(int? bytes, int? limit) {
  if (bytes == null || limit == null || bytes <= limit) return null;
  return 'That file is ${formatByteSize(bytes)}, over this server\'s '
      'limit of ${formatByteSize(limit)} per file.';
}
