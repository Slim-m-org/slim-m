// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser has no file path to stream to; a large file downloads from a link, a small save buffers.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'download_target.dart';

Future<DownloadTarget?> openPlatformDownloadTarget(String filename) async =>
    BrowserDownloadTarget(filename, _download, _downloadLink);

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

/// How long the frame lives; the browser has long since taken the file or shown its error inside it.
const Duration kDownloadFrameLife = Duration(minutes: 2);

/// Loads [link] in a hidden frame, so an error page or a navigation can never replace the app's own document.
web.HTMLIFrameElement downloadInFrame(Uri link) {
  final frame = web.HTMLIFrameElement()
    ..style.display = 'none'
    ..src = link.toString();
  web.document.body?.append(frame);
  Future<void>.delayed(kDownloadFrameLife, () => frame.remove());
  return frame;
}

void _downloadLink(Uri link, String filename) => downloadInFrame(link);
