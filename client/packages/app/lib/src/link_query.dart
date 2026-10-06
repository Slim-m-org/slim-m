// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading a link's query without letting someone else's text throw.
library;

/// [uri]'s query parameters, or null when a percent escape is not valid UTF-8.
Map<String, String>? queryOrNull(Uri uri) {
  try {
    return uri.queryParameters;
  } on FormatException {
    return null;
  }
}
