// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Browsers only let a page write text and PNG images to the clipboard.
library;

import 'dart:typed_data';

import 'clipboard_file_writer.dart';

bool get supported => false;

Future<void> writeFile(Future<Uint8List> bytes, {required String filename}) =>
    throw const ClipboardFileWriteException(
      'Copying files is not supported in the browser.',
    );
