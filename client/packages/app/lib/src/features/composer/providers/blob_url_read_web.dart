// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reads a browser `blob:` URL and frees it.
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// The recorder leaves its URL alive on a normal stop, which pins the whole recording until the page unloads.
Future<Uint8List> readAndRevokeBlobUrl(String url) async {
  try {
    return (await http.get(Uri.parse(url))).bodyBytes;
  } finally {
    web.URL.revokeObjectURL(url);
  }
}
