// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading a link's query without letting someone else's text throw.
library;

import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// [uri]'s query parameters, or null when a percent escape is not valid UTF-8.
Map<String, String>? queryOrNull(Uri uri) {
  try {
    return uri.queryParameters;
  } on FormatException catch (error, stack) {
    AppLog.swallowed(
      LogTag.ui,
      'Could not read the parameters of a link',
      error,
      stack,
    );
    return null;
  }
}
