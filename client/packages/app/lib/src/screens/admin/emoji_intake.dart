// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turning whatever was dropped or picked - images, zips, or a mix - into one
/// plan, through the same naming and size rules a zip alone already used.
library;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'emoji_bulk_plan.dart';

/// One file handed to the emoji card, before it is known to be an image or a zip.
class EmojiPick {
  const EmojiPick({required this.fileName, required this.bytes});
  final String fileName;
  final List<int> bytes;
}

/// Picks any number of images and zips; empty when nothing was chosen.
typedef EmojiFilesPicker = Future<List<EmojiPick>> Function();

/// Injectable because `file_picker` has no platform implementation under test.
final emojiFilesPickerProvider = Provider<EmojiFilesPicker>(
  (ref) => _pickFiles,
);

/// `FileType.custom`, not `FileType.image`: on iOS the latter opens only the
/// Photos-backed picker, which cannot see a file that arrived by download.
Future<List<EmojiPick>> _pickFiles() async {
  final files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const [...acceptedEmojiExtensions, 'zip'],
  );
  // readAsBytes streams from disk since eager loading OOMs on a large pick.
  return [
    for (final f in files)
      EmojiPick(fileName: f.name, bytes: await f.readAsBytes()),
  ];
}

/// Reads every dropped file; a folder is named and left for the plan to refuse.
Future<List<EmojiPick>> readDroppedEmoji(List<DropItem> items) async => [
  for (final item in items)
    EmojiPick(
      fileName: item is DropItemDirectory ? '${item.name}/' : item.name,
      bytes: item is DropItemDirectory ? const [] : await item.readAsBytes(),
    ),
];

bool _isZip(String name) => name.toLowerCase().endsWith('.zip');

/// Plans every pick together: zips expand into their images, loose files are
/// planned as they are, and one name pool keeps a clash across sources a skip.
EmojiZipPlan planEmojiPicks(
  List<EmojiPick> picks, {
  Set<String> existingNames = const {},
}) {
  final entries = <ZipEntryData>[];
  final refused = <SkippedZipEntry>[];
  for (final pick in picks) {
    if (pick.fileName.endsWith('/')) {
      refused.add(
        SkippedZipEntry(
          fileName: pick.fileName,
          reason: 'folders cannot be dropped, zip it first',
        ),
      );
    } else if (_isZip(pick.fileName)) {
      try {
        entries.addAll(decodeEmojiZipEntries(pick.bytes));
      } on ZipTooLargeException {
        refused.add(
          SkippedZipEntry(
            fileName: pick.fileName,
            reason: 'too large to import',
          ),
        );
      } catch (_) {
        refused.add(
          SkippedZipEntry(
            fileName: pick.fileName,
            reason: 'could not be read as a zip',
          ),
        );
      }
    } else {
      entries.add(ZipEntryData(path: pick.fileName, bytes: pick.bytes));
    }
  }
  final plan = planEmojiZip(entries, existingNames: existingNames);
  return EmojiZipPlan(
    uploads: plan.uploads,
    skipped: [...refused, ...plan.skipped],
  );
}
