// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading and writing a theme file (decision 0106) through the file picker.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../downloads/download_target.dart';

class ThemeFilePick {
  const ThemeFilePick({required this.fileName, required this.bytes});

  final String fileName;
  final List<int> bytes;
}

/// Null when nothing was chosen.
typedef ThemeFilePicker = Future<ThemeFilePick?> Function();

/// False when the person dismissed the save step.
typedef ThemeFileSaver =
    Future<bool> Function(String fileName, List<int> bytes);

/// Injectable because `file_picker` has no platform implementation under test.
final themeFilePickerProvider = Provider<ThemeFilePicker>((ref) => _pick);

final themeFileSaverProvider = Provider<ThemeFileSaver>((ref) => _save);

/// `FileType.custom`, not a media type: on iOS the latter opens only the Photos picker.
Future<ThemeFilePick?> _pick() async {
  final files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['json'],
  );
  final file = files.firstOrNull;
  if (file == null) return null;
  return ThemeFilePick(fileName: file.name, bytes: await file.readAsBytes());
}

Future<bool> _save(String fileName, List<int> bytes) async {
  final target = await openDownloadTarget(fileName);
  if (target == null) return false;
  await target.write(bytes);
  return target.finish();
}

/// The name an exported theme is saved under.
String themeFileName(String themeName) {
  final slug = themeName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return '${slug.isEmpty ? 'theme' : slug}.slimm-theme.json';
}

/// The file's theme, or every problem found reading it.
ThemeParse readThemeFile(List<int> bytes) {
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return const ThemeParse.failed(['The file is not text.']);
  }
  return parseThemeFile(text);
}
