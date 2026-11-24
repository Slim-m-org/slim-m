// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser has no file path to stream to; it buffers and downloads at the end.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'download_target.dart';

Future<DownloadTarget?> openPlatformDownloadTarget(String filename) async =>
    BrowserDownloadTarget(filename, _download);

void _download(Uint8List bytes, String filename) {
  final blob = web.Blob([bytes.toJS].toJS);
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  anchor.click();
  // The browser starts the download asynchronously, so the URL must outlive the click.
  Future<void>.delayed(
    const Duration(seconds: 30),
    () => web.URL.revokeObjectURL(url),
  );
}
