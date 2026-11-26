// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The photo picker's cache copies are deleted, and only those.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/system_photo_picker.dart';

void main() {
  late Directory cache;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('picked-copies-');
  });
  tearDown(() => cache.delete(recursive: true));

  Future<File> copy(String folder, String name) async {
    final dir = await Directory('${cache.path}/$folder').create();
    return File('${dir.path}/$name').writeAsString('x');
  }

  test('a recorded pick loses its own folder and nothing else', () async {
    final mine = await copy('u1', 'a.jpg');
    final other = await copy('u2', 'b.jpg');

    await deletePickedCopies([mine.path], cache.path);

    expect(mine.parent.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
  });

  test('a path outside the cache root is left alone', () async {
    final nested = await Directory(
      '${cache.path}/u1/deeper',
    ).create(recursive: true);
    final file = await File('${nested.path}/a.jpg').writeAsString('x');

    await deletePickedCopies([file.path], cache.path);

    expect(file.existsSync(), isTrue);
  });

  test('the log hands over what was recorded once', () {
    final log = PickedCopyLog()..record(['a', 'b', 'a']);
    expect(log.drain(), ['a', 'b']);
    expect(log.drain(), isEmpty);
  });
}
