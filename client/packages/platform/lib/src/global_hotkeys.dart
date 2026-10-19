// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hotkeys that fire while another app, a game say, has focus.
///
/// Linux uses the desktop portal's GlobalShortcuts, Windows a low-level
/// keyboard hook in the runner. Everywhere else [createGlobalHotkeySource] is
/// null and the in-window handlers stay the only path.
library;

import 'package:flutter/services.dart';

import 'global_hotkeys_stub.dart' if (dart.library.io) 'global_hotkeys_io.dart'
    as impl;

/// What a global hotkey does; [name] doubles as its id on the wire.
enum GlobalHotkeyId { pushToTalk, toggleMute, toggleDeafen }

/// A key plus the modifiers that must be held with it.
class HotkeyChord {
  const HotkeyChord(
    this.key, {
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
  });

  final LogicalKeyboardKey key;
  final bool ctrl;
  final bool alt;
  final bool shift;
  final bool meta;
}

class GlobalHotkeyBinding {
  const GlobalHotkeyBinding({
    required this.id,
    required this.description,
    required this.chord,
  });

  final GlobalHotkeyId id;

  /// What the OS shows next to the shortcut when it asks the person to approve it.
  final String description;
  final HotkeyChord chord;
}

enum GlobalHotkeyPhase {
  pressed,
  released,

  /// Capture stopped (hook gone, session closed): every hold must end.
  lost,
}

class GlobalHotkeyEvent {
  const GlobalHotkeyEvent(this.id, this.phase);

  const GlobalHotkeyEvent.lost()
      : id = null,
        phase = GlobalHotkeyPhase.lost;

  final GlobalHotkeyId? id;
  final GlobalHotkeyPhase phase;
}

/// Whether global capture can work here, with the line settings shows for it.
class GlobalHotkeyAvailability {
  const GlobalHotkeyAvailability.available(this.message) : available = true;

  const GlobalHotkeyAvailability.unavailable(this.message) : available = false;

  final bool available;
  final String message;
}

abstract interface class GlobalHotkeySource {
  /// Cheap check that asks the OS for nothing the person would see.
  Future<GlobalHotkeyAvailability> probe();

  /// Replaces the registered set; may show an OS approval prompt.
  Future<GlobalHotkeyAvailability> bind(List<GlobalHotkeyBinding> bindings);

  /// Presses and releases, plus [GlobalHotkeyPhase.lost] when capture dies.
  Stream<GlobalHotkeyEvent> get events;

  Future<void> dispose();
}

/// The source for this platform, or null when there is none.
GlobalHotkeySource? createGlobalHotkeySource() =>
    impl.createGlobalHotkeySource();
