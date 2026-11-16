// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Choosing the audio file a soundboard clip is made from.
library;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show SoundClip;

import '../../../../hidden_characters.dart';

/// Largest clip the server accepts, so a bigger file is refused before it is sent.
const soundClipMaxBytes = 512 * 1024;

/// The longest name a clip may have, mirrored from the server.
const soundClipMaxNameChars = 32;

/// One chosen file, before it is uploaded.
class SoundClipPick {
  const SoundClipPick({required this.fileName, required this.bytes});
  final String fileName;
  final List<int> bytes;

  /// The file's name without its extension, cut to what a clip may be called.
  String get suggestedName {
    final dot = fileName.lastIndexOf('.');
    final stem = (dot > 0 ? fileName.substring(0, dot) : fileName).trim();
    return String.fromCharCodes(stem.runes.take(soundClipMaxNameChars));
  }
}

/// Why [pick] cannot become a clip whatever it is named, or null.
String? soundClipFileProblem(SoundClipPick pick) {
  final name = pick.fileName.toLowerCase();
  if (!name.endsWith('.mp3') && !name.endsWith('.wav')) {
    return 'Only mp3 and wav files can be clips.';
  }
  if (pick.bytes.length > soundClipMaxBytes) {
    return 'That file is over 512 KB. A clip is at most 512 KB.';
  }
  return null;
}

/// Why [name] cannot be used next to [clips], or null; [renaming] is the clip whose own name it may keep.
String? soundClipNameProblem(
  String name,
  List<SoundClip> clips, {
  String? renaming,
}) {
  if (name.runes.any(isHiddenCharacter)) {
    return 'Names cannot hold hidden characters.';
  }
  final folded = _foldAscii(name);
  final taken = clips.any(
    (c) => c.id != renaming && _foldAscii(c.name) == folded,
  );
  return taken ? 'A clip already has that name.' : null;
}

// The server compares names with SQLite's NOCASE, which folds ASCII letters only.
String _foldAscii(String s) => String.fromCharCodes([
  for (final c in s.codeUnits) c >= 0x41 && c <= 0x5A ? c + 0x20 : c,
]);

/// The first of [items] that is a file, read whole; null for a folder alone.
Future<SoundClipPick?> readDroppedSoundClip(List<DropItem> items) async {
  for (final item in items) {
    if (item is DropItemDirectory) continue;
    return SoundClipPick(fileName: item.name, bytes: await item.readAsBytes());
  }
  return null;
}

/// Picks one mp3 or wav file; null when nothing was chosen.
typedef SoundClipPicker = Future<SoundClipPick?> Function();

/// Injectable because `file_picker` has no platform implementation under test.
final soundClipPickerProvider = Provider<SoundClipPicker>((ref) => _pick);

Future<SoundClipPick?> _pick() async {
  final files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['mp3', 'wav'],
  );
  if (files.isEmpty) return null;
  final file = files.first;
  return SoundClipPick(fileName: file.name, bytes: await file.readAsBytes());
}
