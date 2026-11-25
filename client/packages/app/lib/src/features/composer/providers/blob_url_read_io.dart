// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// There are no blob URLs outside a browser.
library;

import 'dart:typed_data';

Future<Uint8List> readAndRevokeBlobUrl(String url) =>
    throw UnsupportedError('blob: URLs exist only in a browser');
