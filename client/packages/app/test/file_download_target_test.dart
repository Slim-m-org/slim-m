// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop target writes beside the chosen file and renames when complete.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/downloads/download_target_io.dart';

void main() {
  late Directory dir;
  late File chosen;
  late File part;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-download-target');
    addTearDown(() => dir.delete(recursive: true));
    chosen = File('${dir.path}/out.bin');
    part = File('${chosen.path}.part');
  });

  test('finish renames the finished file over the chosen name', () async {
    await chosen.writeAsBytes(const []);
    final target = await FileDownloadTarget.open(chosen);
    await target.write([1, 2]);
    await target.write([3]);
    expect(await chosen.length(), 0, reason: 'nothing under the real name yet');

    expect(await target.finish(), isTrue);

    expect(await chosen.readAsBytes(), [1, 2, 3]);
    expect(part.existsSync(), isFalse);
  });

  test('discard removes the partial and the empty placeholder', () async {
    await chosen.writeAsBytes(const []);
    final target = await FileDownloadTarget.open(chosen);
    await target.write([1]);

    await target.discard();

    expect(part.existsSync(), isFalse);
    expect(chosen.existsSync(), isFalse);
  });

  test('a failed download never touches a file that has content', () async {
    await chosen.writeAsBytes(const [9, 9]);
    final target = await FileDownloadTarget.open(chosen);
    await target.write([1]);
    await target.discard();

    expect(await chosen.readAsBytes(), [9, 9]);
    expect(part.existsSync(), isFalse);
  });

  test('a close that throws does not skip the delete', () async {
    final target = await FileDownloadTarget.open(chosen);
    await target.write([1]);
    await target.finish();
    await chosen.delete();
    await part.writeAsBytes(const [1]);

    await target.discard();

    expect(part.existsSync(), isFalse);
  });

  test('a write after a discard is refused, not silently dropped', () async {
    final target = await FileDownloadTarget.open(chosen);
    await target.discard();
    expect(() => target.write([1]), throwsA(isA<FileSystemException>()));
  });
}
