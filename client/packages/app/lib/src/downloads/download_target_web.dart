// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser has no file path to stream to; it buffers and downloads at the end.
library;

import 'download_target.dart';

Future<DownloadTarget?> openPlatformDownloadTarget(String filename) async =>
    MemoryDownloadTarget(filename);
