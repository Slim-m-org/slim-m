// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web voice recorder hands back a `blob:` URL; reading it must free it.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/providers/blob_url_read.dart';
import 'package:web/web.dart' as web;

void main() {
  test('reading a blob URL returns its bytes and revokes the URL', () async {
    final blob = web.Blob(
      [
        Uint8List.fromList([1, 2, 3]).toJS,
      ].toJS,
    );
    final url = web.URL.createObjectURL(blob);

    final bytes = await readAndRevokeBlobUrl(url);

    expect(bytes, [1, 2, 3]);
    final again = await web.window
        .fetch(url.toJS)
        .toDart
        .then((r) => r.ok, onError: (_) => false);
    expect(again, isFalse);
  });
}
