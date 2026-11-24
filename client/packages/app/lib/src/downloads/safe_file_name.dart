// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One file-name sanitizer for everything the app saves under a remote-supplied name.
library;

import 'dart:convert';

final RegExp _windowsForbidden = RegExp(r'[<>:"|?*\u0000-\u001f\u007f]');
final RegExp _controls = RegExp(r'[\u0000-\u001f\u007f]');
final RegExp _reservedDevice = RegExp(
  r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])$',
  caseSensitive: false,
);

/// Bytes left for the name once ` (n)` and `.part` are added to a 255 byte NAME_MAX.
const int safeFileNameMaxBytes = 240;
const int _suffixReserve = 12;
const int _maxExtensionBytes = 32;

/// [name] as a single path segment that every desktop file system accepts.
///
/// Windows rules are applied when [windows] is set; the byte cap always applies,
/// cut on a code point boundary so the result stays valid UTF-8.
String safeFileName(
  String name, {
  required bool windows,
  String fallback = 'download',
}) {
  final segment = name.split(RegExp(r'[\\/]')).last;
  var clean = segment.replaceAll(windows ? _windowsForbidden : _controls, '_');
  if (windows) clean = clean.replaceFirst(RegExp(r'[. ]+$'), '');
  if (clean.isEmpty || clean == '.' || clean == '..') return fallback;
  clean = _capBytes(clean);
  if (windows && _reservedDevice.hasMatch(clean.split('.').first.trim())) {
    clean = '_$clean';
  }
  return clean;
}

String _capBytes(String name) {
  const budget = safeFileNameMaxBytes - _suffixReserve;
  if (utf8.encode(name).length <= budget) return name;
  final dot = name.lastIndexOf('.');
  final extension = dot > 0 ? name.substring(dot) : '';
  final keep = utf8.encode(extension).length <= _maxExtensionBytes
      ? extension
      : '';
  final stem = keep.isEmpty ? name : name.substring(0, dot);
  final room = budget - utf8.encode(keep).length;
  final out = StringBuffer();
  var used = 0;
  for (final rune in stem.runes) {
    final piece = String.fromCharCode(rune);
    used += utf8.encode(piece).length;
    if (used > room) break;
    out.write(piece);
  }
  return '$out$keep';
}
