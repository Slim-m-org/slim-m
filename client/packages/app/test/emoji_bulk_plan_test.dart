// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the pure derivation behind bulk emoji import (backlog #137):
/// given a zip's decoded entries, which become planned uploads, which are
/// skipped, and why.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/admin/emoji_bulk_plan.dart';

import 'emoji_add_harness.dart' show buildEmojiZip;

ZipEntryData _file(String path, {List<int>? bytes}) =>
    ZipEntryData(path: path, bytes: bytes ?? [1, 2, 3]);

ZipEntryData _dir(String path) =>
    ZipEntryData(path: path, bytes: const [], isFile: false);

void main() {
  test('directories are skipped silently and a non-image is named', () {
    final plan = planEmojiZip([
      _dir('icons/'),
      _file('readme.txt'),
      _file('icons/party_blob.gif'),
    ]);

    expect(plan.uploads, hasLength(1));
    expect(plan.uploads.single.name, 'party_blob');
    expect(plan.skipped, hasLength(1));
    expect(plan.skipped.single.fileName, 'readme.txt');
    expect(plan.skipped.single.reason, contains('not a PNG'));
  });

  test('the emoji name is the file stem, sanitized the same way typing one '
      'by one is', () {
    final plan = planEmojiZip([_file('Party Parrot.PNG')]);

    expect(plan.uploads, hasLength(1));
    expect(plan.uploads.single.name, 'party_parrot');
    expect(plan.uploads.single.fileName, 'Party Parrot.PNG');
  });

  test(
    'a directory prefix is stripped, only the file name names the emoji',
    () {
      final plan = planEmojiZip([_file('emoji/nested/smile.png')]);

      expect(plan.uploads.single.fileName, 'smile.png');
      expect(plan.uploads.single.name, 'smile');
    },
  );

  test('a name that sanitizes to nothing is skipped with a reason', () {
    final plan = planEmojiZip([_file('!!!.png')]);

    expect(plan.uploads, isEmpty);
    expect(plan.skipped, hasLength(1));
    expect(plan.skipped.single.fileName, '!!!.png');
    expect(plan.skipped.single.reason, contains('no usable name'));
  });

  test('two files that sanitize to the same name: the first wins, the '
      'second is reported as a collision', () {
    final plan = planEmojiZip([_file('Smile.png'), _file('smile.gif')]);

    expect(plan.uploads, hasLength(1));
    expect(plan.uploads.single.fileName, 'Smile.png');
    expect(plan.skipped, hasLength(1));
    expect(plan.skipped.single.fileName, 'smile.gif');
    expect(plan.skipped.single.reason, contains(':smile:'));
  });

  test('a name already used by an existing emoji is refused before any '
      'request, not left to a 409 partway through the batch', () {
    final plan = planEmojiZip(
      [_file('party_parrot.png')],
      existingNames: {'party_parrot'},
    );

    expect(plan.uploads, isEmpty);
    expect(plan.skipped.single.reason, contains(':party_parrot:'));
  });

  test('a file over the 1 MB server limit is refused up front', () {
    final plan = planEmojiZip([
      _file('huge.png', bytes: List.filled(maxPlannedEmojiBytes + 1, 0)),
    ]);

    expect(plan.uploads, isEmpty);
    expect(plan.skipped.single.reason, contains('larger than 1 MB'));
  });

  test(
    'an empty file is refused rather than uploaded as a zero-byte image',
    () {
      final plan = planEmojiZip([_file('blank.png', bytes: const [])]);

      expect(plan.uploads, isEmpty);
      expect(plan.skipped.single.reason, contains('empty'));
    },
  );

  test('macOS AppleDouble sidecar junk is skipped, not queued as garbage', () {
    final plan = planEmojiZip([
      _file('__MACOSX/._smile.png'),
      _file('smile.png'),
    ]);

    expect(plan.uploads, hasLength(1));
    expect(plan.uploads.single.fileName, 'smile.png');
    expect(plan.skipped, isEmpty);
  });

  test('a batch past the per-zip cap reports the overflow rather than '
      'queuing it', () {
    final entries = [
      for (var i = 0; i < maxPlannedEmojiCount + 1; i++) _file('e$i.png'),
    ];

    final plan = planEmojiZip(entries);

    expect(plan.uploads, hasLength(maxPlannedEmojiCount));
    expect(plan.skipped, hasLength(1));
    expect(plan.skipped.single.reason, contains('more than'));
  });

  test('decoding a real zip built with the archive encoder round-trips '
      'through the same plan', () {
    final archive = Archive()
      ..addFile(ArchiveFile('party_blob.gif', 3, Uint8List.fromList([1, 2, 3])))
      ..addFile(
        ArchiveFile('notes/readme.txt', 4, Uint8List.fromList([0, 0, 0, 0])),
      );
    final zipBytes = ZipEncoder().encodeBytes(archive);

    final entries = decodeEmojiZipEntries(zipBytes);
    final plan = planEmojiZip(entries);

    expect(plan.uploads, hasLength(1));
    expect(plan.uploads.single.name, 'party_blob');
    expect(plan.uploads.single.bytes, [1, 2, 3]);
    expect(plan.skipped.single.fileName, 'readme.txt');
  });

  test('bytes that are not a zip at all decode to no entries, which plans '
      'to nothing rather than crashing', () {
    final entries = decodeEmojiZipEntries([1, 2, 3, 4]);

    expect(entries, isEmpty);
    expect(planEmojiZip(entries).uploads, isEmpty);
  });

  test('a non-image entry is never inflated, however large it declares '
      'itself', () {
    const size = 64 * 1024 * 1024;
    final archive = Archive()
      ..addFile(ArchiveFile('notes.bin', size, Uint8List(size)))
      ..addFile(ArchiveFile('ok.png', 3, Uint8List.fromList([1, 2, 3])));

    final entries = decodeEmojiZipEntries(ZipEncoder().encodeBytes(archive));

    final held = entries.fold<int>(0, (n, e) => n + e.bytes.length);
    expect(held, lessThan(maxPlannedEmojiBytes));
    expect(planEmojiZip(entries).uploads.map((u) => u.name), ['ok']);
  });

  test('an image over the cap is refused by its declared size without being '
      'inflated', () {
    const size = maxPlannedEmojiBytes + 1;
    final archive = Archive()
      ..addFile(ArchiveFile('big.png', size, Uint8List(size)));

    final entries = decodeEmojiZipEntries(ZipEncoder().encodeBytes(archive));
    final plan = planEmojiZip(entries);

    expect(entries.single.bytes, isEmpty);
    expect(plan.uploads, isEmpty);
    expect(plan.skipped.single.reason, 'larger than 1 MB');
  });

  test('a zip with more entries than the cap is refused unread', () {
    final zip = buildEmojiZip({
      for (var i = 0; i <= maxZipEntries; i++) 'f$i.txt': [1],
    });
    expect(
      () => decodeEmojiZipEntries(zip),
      throwsA(isA<ZipTooLargeException>()),
    );
  });

  test('a real small zip decodes to its images only', () {
    final entries = decodeEmojiZipEntries(
      buildEmojiZip({
        'a.png': [1, 2],
        'notes.txt': [3],
      }),
    );
    final plan = planEmojiZip(entries);
    expect(plan.uploads.single.name, 'a');
    expect(plan.skipped.single.fileName, 'notes.txt');
  });
}
