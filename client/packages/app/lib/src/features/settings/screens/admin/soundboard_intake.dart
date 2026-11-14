// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Choosing the audio file a soundboard clip is made from.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
