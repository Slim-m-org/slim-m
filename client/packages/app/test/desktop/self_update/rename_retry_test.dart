// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/self_update/install_fs.dart';

void main() {
  test('waits the backoff between attempts', () async {
    var attempts = 0;
    final watch = Stopwatch()..start();
    await renameDirectoryWithRetry(
      Directory('a'),
      'b',
      rename: (_, _) async {
        if (++attempts < 3) {
          throw const FileSystemException('busy', 'a', OSError('', 5));
        }
      },
      backoff: const [Duration(milliseconds: 40), Duration(milliseconds: 40)],
    );
    expect(attempts, 3);
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(70));
  });
}
