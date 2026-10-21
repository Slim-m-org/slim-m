// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A file that was never cached is a normal miss: null, and nothing logged.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show AppLog, LogRecord, LogSink;
import 'package:slimm_app/src/providers/disk_byte_cache.dart';

class _Records implements LogSink {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

void main() {
  test(
    'reading a key that is not cached returns null without logging',
    () async {
      final dir = Directory.systemTemp.createTempSync('byte-cache-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final sink = _Records();
      AppLog.install(sink);
      addTearDown(() => AppLog.install(null));
      final cache = DiskByteCache(
        dirName: 'avatars',
        ceilingBytes: 1024,
        directory: dir,
      );

      expect(await cache.read('nobody'), isNull);
      expect(sink.records, isEmpty);

      await cache.write('somebody', Uint8List.fromList([1, 2]));
      expect(await cache.read('somebody'), isNotNull);
    },
  );
}
