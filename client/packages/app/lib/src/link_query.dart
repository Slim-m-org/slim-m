// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading a link's query without letting someone else's text throw.
library;

import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// [uri]'s query parameters, or null when a percent escape is not valid UTF-8.
Map<String, String>? queryOrNull(Uri uri) {
  try {
    return uri.queryParameters;
  } on FormatException catch (error, stack) {
    AppLog.swallowed(LogTag.ui, 'query or null failed, ignored', error, stack);
    return null;
  }
}
