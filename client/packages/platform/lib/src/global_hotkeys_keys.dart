// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Key names each OS wants a global hotkey registered by.
library;

import 'package:flutter/services.dart';

import 'global_hotkeys.dart';

final _windowsVirtualKeys = <LogicalKeyboardKey, int>{
  LogicalKeyboardKey.backspace: 0x08,
  LogicalKeyboardKey.pause: 0x13,
  LogicalKeyboardKey.capsLock: 0x14,
  LogicalKeyboardKey.space: 0x20,
  LogicalKeyboardKey.pageUp: 0x21,
  LogicalKeyboardKey.pageDown: 0x22,
  LogicalKeyboardKey.end: 0x23,
  LogicalKeyboardKey.home: 0x24,
  LogicalKeyboardKey.arrowLeft: 0x25,
  LogicalKeyboardKey.arrowUp: 0x26,
  LogicalKeyboardKey.arrowRight: 0x27,
  LogicalKeyboardKey.arrowDown: 0x28,
  LogicalKeyboardKey.insert: 0x2D,
  LogicalKeyboardKey.delete: 0x2E,
  LogicalKeyboardKey.scrollLock: 0x91,
  LogicalKeyboardKey.shiftLeft: 0xA0,
  LogicalKeyboardKey.shiftRight: 0xA1,
  LogicalKeyboardKey.controlLeft: 0xA2,
  LogicalKeyboardKey.controlRight: 0xA3,
  LogicalKeyboardKey.altLeft: 0xA4,
  LogicalKeyboardKey.altRight: 0xA5,
  LogicalKeyboardKey.semicolon: 0xBA,
  LogicalKeyboardKey.equal: 0xBB,
  LogicalKeyboardKey.comma: 0xBC,
  LogicalKeyboardKey.minus: 0xBD,
  LogicalKeyboardKey.period: 0xBE,
  LogicalKeyboardKey.slash: 0xBF,
  LogicalKeyboardKey.backquote: 0xC0,
  LogicalKeyboardKey.bracketLeft: 0xDB,
  LogicalKeyboardKey.backslash: 0xDC,
  LogicalKeyboardKey.bracketRight: 0xDD,
  LogicalKeyboardKey.quote: 0xDE,
  LogicalKeyboardKey.numpadMultiply: 0x6A,
  LogicalKeyboardKey.numpadAdd: 0x6B,
  LogicalKeyboardKey.numpadSubtract: 0x6D,
  LogicalKeyboardKey.numpadDecimal: 0x6E,
  LogicalKeyboardKey.numpadDivide: 0x6F,
  for (var i = 0; i < 10; i++) _numpadKeys[i]: 0x60 + i,
  for (var i = 0; i < 24; i++) _functionKey(i + 1): 0x70 + i,
};

final _numpadKeys = [
  LogicalKeyboardKey.numpad0,
  LogicalKeyboardKey.numpad1,
  LogicalKeyboardKey.numpad2,
  LogicalKeyboardKey.numpad3,
  LogicalKeyboardKey.numpad4,
  LogicalKeyboardKey.numpad5,
  LogicalKeyboardKey.numpad6,
  LogicalKeyboardKey.numpad7,
  LogicalKeyboardKey.numpad8,
  LogicalKeyboardKey.numpad9,
];

LogicalKeyboardKey _functionKey(int n) => switch (n) {
      1 => LogicalKeyboardKey.f1,
      2 => LogicalKeyboardKey.f2,
      3 => LogicalKeyboardKey.f3,
      4 => LogicalKeyboardKey.f4,
      5 => LogicalKeyboardKey.f5,
      6 => LogicalKeyboardKey.f6,
      7 => LogicalKeyboardKey.f7,
      8 => LogicalKeyboardKey.f8,
      9 => LogicalKeyboardKey.f9,
      10 => LogicalKeyboardKey.f10,
      11 => LogicalKeyboardKey.f11,
      12 => LogicalKeyboardKey.f12,
      13 => LogicalKeyboardKey.f13,
      14 => LogicalKeyboardKey.f14,
      15 => LogicalKeyboardKey.f15,
      16 => LogicalKeyboardKey.f16,
      17 => LogicalKeyboardKey.f17,
      18 => LogicalKeyboardKey.f18,
      19 => LogicalKeyboardKey.f19,
      20 => LogicalKeyboardKey.f20,
      21 => LogicalKeyboardKey.f21,
      22 => LogicalKeyboardKey.f22,
      23 => LogicalKeyboardKey.f23,
      _ => LogicalKeyboardKey.f24,
    };

final _letterOrDigit = RegExp(r'^[a-zA-Z0-9]$');

/// The Windows virtual-key code for [key], or null when it has none.
int? windowsVirtualKeyFor(LogicalKeyboardKey key) {
  final named = _windowsVirtualKeys[key];
  if (named != null) return named;
  final label = key.keyLabel;
  if (!_letterOrDigit.hasMatch(label)) return null;
  return label.toUpperCase().codeUnitAt(0);
}

/// The portal's `preferred_trigger` for [chord], or null to suggest none.
///
/// A bare letter or digit is never suggested: a portal shortcut is an
/// exclusive grab, so it would stop that key working in every other app.
String? portalTriggerFor(HotkeyChord chord) {
  final key = _xkbName(chord.key);
  if (key == null) return null;
  final hasModifier = chord.ctrl || chord.alt || chord.shift || chord.meta;
  if (!hasModifier && _letterOrDigit.hasMatch(key)) return null;
  return [
    if (chord.ctrl) 'CTRL',
    if (chord.alt) 'ALT',
    if (chord.shift) 'SHIFT',
    if (chord.meta) 'LOGO',
    key,
  ].join('+');
}

String? _xkbName(LogicalKeyboardKey key) {
  final label = key.keyLabel;
  if (_letterOrDigit.hasMatch(label)) return label.toLowerCase();
  final function = RegExp(r'^F([0-9]{1,2})$').firstMatch(label);
  return function == null ? null : 'F${function.group(1)}';
}
