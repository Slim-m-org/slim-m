// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picked zips that are valid in shape but wrong inside: an entry that will not
/// inflate, or a header that understates the image, are refused per entry and
/// never escape the plan.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/screens/admin/emoji_bulk_plan.dart';
import 'package:slimm_app/src/features/settings/screens/admin/emoji_intake.dart';

import 'emoji_add_harness.dart';

const _localHeaderBytes = 30;
const _localSizeOffset = 22;
const _centralSizeOffset = 24;

Uint8List _zipOf(Map<String, Uint8List> files) {
  final archive = Archive();
  for (final e in files.entries) {
    archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

final _compressible = Uint8List.fromList(
  List.generate(4000, (i) => (i * 7) % 251),
);

// 0xFF opens a deflate block of the reserved type, which no inflater accepts.
Uint8List _withBrokenDeflate(Uint8List zip, String entryName) {
  final bad = Uint8List.fromList(zip);
  bad[_localHeaderBytes + entryName.length] = 0xFF;
  return bad;
}

Uint8List _withDeclaredSize(Uint8List zip, int size) {
  final patched = Uint8List.fromList(zip);
  final view = ByteData.view(patched.buffer);
  view.setUint32(_localSizeOffset, size, Endian.little);
  for (var i = 0; i + 4 <= patched.length; i++) {
    final isCentralHeader = view.getUint32(i, Endian.little) == 0x02014b50;
    if (isCentralHeader) {
      view.setUint32(i + _centralSizeOffset, size, Endian.little);
    }
  }
  return patched;
}

EmojiZipPlan _plan(String zipName, Uint8List zip) =>
    planEmojiPicks([EmojiPick(fileName: zipName, bytes: zip)]);

void main() {
  test('an entry that will not inflate is refused by name and the rest of '
      'the pack still imports', () {
    final zip = _withBrokenDeflate(
      _zipOf({'bad.png': _compressible, 'good.png': emojiTestPng}),
      'bad.png',
    );

    final plan = _plan('pack.zip', zip);

    expect(plan.uploads.map((u) => u.name), ['good']);
    expect(plan.skipped.single.fileName, 'bad.png');
    expect(plan.skipped.single.reason, 'could not be read from the zip');
  });

  test('a header that understates an image does not get it past the 1 MB '
      'cap', () {
    final big = Uint8List(maxPlannedEmojiBytes * 3);
    final zip = _withDeclaredSize(_zipOf({'big.png': big}), 500);

    final plan = _plan('lying.zip', zip);

    expect(plan.uploads, isEmpty);
    expect(plan.skipped.single.fileName, 'big.png');
    expect(plan.skipped.single.reason, 'larger than 1 MB');
  });

  test('a corrupt entry does not claim its name from a later good one', () {
    final zip = _withBrokenDeflate(
      _zipOf({'a.png': _compressible, 'a.gif': emojiTestPng}),
      'a.png',
    );

    final plan = _plan('pack.zip', zip);

    expect(plan.uploads.map((u) => u.fileName), ['a.gif']);
    expect(plan.skipped.single.fileName, 'a.png');
  });
}
