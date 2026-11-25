// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One file name that is safe to create on Linux, macOS and Windows alike.
library;

import 'dart:convert';

const int _maxNameBytes = 200;

final RegExp _unsafeChars = RegExp(r'[\\/:*?"<>|\x00-\x1f]');
final RegExp _deviceName = RegExp(
  r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])$',
  caseSensitive: false,
);

/// [filename] reduced to a single path segment that no platform treats specially.
///
/// Replaces separators and Windows-forbidden characters, drops trailing dots
/// and spaces, prefixes a Windows device name, and caps the byte length.
String safeFileName(String filename, {String fallback = 'file'}) {
  var name = filename.replaceAll(_unsafeChars, '_').trim();
  name = name.replaceFirst(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) return fallback;
  final dot = name.indexOf('.');
  final stem = (dot < 0 ? name : name.substring(0, dot)).trimRight();
  if (_deviceName.hasMatch(stem)) name = '_$name';
  return _capBytes(name);
}

String _capBytes(String name) {
  if (utf8.encode(name).length <= _maxNameBytes) return name;
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 && name.length - dot <= 16 ? name.substring(dot) : '';
  final runes = (ext.isEmpty ? name : name.substring(0, dot)).runes.toList();
  while (runes.isNotEmpty &&
      utf8.encode(String.fromCharCodes(runes)).length +
              utf8.encode(ext).length >
          _maxNameBytes) {
    runes.removeLast();
  }
  return '${String.fromCharCodes(runes)}$ext';
}
