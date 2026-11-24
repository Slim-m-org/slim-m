// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop target writes beside the chosen file and renames when complete.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/downloads/download_target_io.dart';

List<FileSystemEntity> _partFiles(Directory d) => d.existsSync()
    ? d.listSync().where((e) => e.path.endsWith('.part')).toList()
    : const [];

void main() {
  late Directory dir;
  late File chosen;
  late Directory parts;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-download-target');
    addTearDown(() => dir.delete(recursive: true));
    chosen = File('${dir.path}/out.bin');
    parts = Directory('${dir.path}/parts');
  });

  test('finish renames the finished file over the chosen name', () async {
    await chosen.writeAsBytes(const []);
    final target = await FileDownloadTarget.open(chosen, partDirectory: parts);
    await target.write([1, 2]);
    await target.write([3]);
    expect(await chosen.length(), 0, reason: 'nothing under the real name yet');

    expect(await target.finish(), isTrue);

    expect(await chosen.readAsBytes(), [1, 2, 3]);
    expect(_partFiles(parts), isEmpty);
  });

  test('discard removes the partial and the empty placeholder', () async {
    await chosen.writeAsBytes(const []);
    final target = await FileDownloadTarget.open(chosen, partDirectory: parts);
    await target.write([1]);

    await target.discard();

    expect(_partFiles(parts), isEmpty);
    expect(chosen.existsSync(), isFalse);
  });

  test('a failed download never touches a file that has content', () async {
    await chosen.writeAsBytes(const [9, 9]);
    final target = await FileDownloadTarget.open(chosen, partDirectory: parts);
    await target.write([1]);
    await target.discard();

    expect(await chosen.readAsBytes(), [9, 9]);
    expect(_partFiles(parts), isEmpty);
  });

  test('a close that throws does not skip the delete', () async {
    final target = await FileDownloadTarget.open(chosen, partDirectory: parts);
    await target.write([1]);
    await target.finish();
    await chosen.delete();
    await target.discard();

    expect(_partFiles(parts), isEmpty);
  });

  test('a write after a discard is refused, not silently dropped', () async {
    final target = await FileDownloadTarget.open(chosen, partDirectory: parts);
    await target.discard();
    expect(() => target.write([1]), throwsA(isA<FileSystemException>()));
  });

  test('partials stay out of the target folder while writing', () async {
    await chosen.writeAsBytes(const []);
    final target = await FileDownloadTarget.open(chosen, partDirectory: parts);
    await target.write([1]);
    expect(dir.listSync().whereType<File>().map((f) => f.path), [chosen.path]);
    expect(_partFiles(parts), hasLength(1));
    await target.discard();
  });

  test('two downloads of one name get two files and two partials', () async {
    final a = await freeDownloadFile(dir, 'a.png');
    final b = await freeDownloadFile(dir, 'a.png');
    expect(a.path, isNot(b.path));
    final ta = await FileDownloadTarget.open(a, partDirectory: parts);
    final tb = await FileDownloadTarget.open(b, partDirectory: parts);
    await ta.write([1]);
    await tb.write([2]);
    expect(_partFiles(parts), hasLength(2));
    await ta.finish();
    await tb.finish();
    expect(await a.readAsBytes(), [1]);
    expect(await b.readAsBytes(), [2]);
  });

  test('discard waits for a write in flight and leaves no partial', () async {
    final target = await FileDownloadTarget.open(chosen, partDirectory: parts);
    final write = target.write(List.filled(4 << 20, 7));
    await target.discard();
    await write;
    expect(_partFiles(parts), isEmpty);
    expect(chosen.existsSync(), isFalse);
  });

  test('opening sweeps day-old partials and keeps fresh ones', () async {
    await parts.create(recursive: true);
    final old = File('${parts.path}/old.part')..writeAsBytesSync(const [1]);
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 3)));
    final fresh = File('${parts.path}/fresh.part')..writeAsBytesSync(const [1]);
    final target = await FileDownloadTarget.open(chosen, partDirectory: parts);
    expect(old.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    await target.discard();
  });
}
