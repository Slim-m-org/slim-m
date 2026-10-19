// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The push-to-talk key, as one compact row: the current key as a key cap
/// and a Change button that waits for the next key pressed. Escape cancels.
/// Any single key works. Whether it also works with another app focused is
/// the status line under the shortcuts, from the global hotkey source.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'key_capture_row.dart';

/// Keys that already mean something while choosing, so they cannot be bound.
final _unbindable = {
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.tab,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
};

/// Whether [key] can be the push-to-talk key.
bool canBindPushToTalk(LogicalKeyboardKey key) => !_unbindable.contains(key);

/// A short, readable name for [key] on its key cap.
String pushToTalkKeyName(LogicalKeyboardKey key) {
  final label = key.keyLabel.trim();
  if (label.isNotEmpty) return label.length == 1 ? label.toUpperCase() : label;
  return key.debugName ?? 'Key ${key.keyId}';
}

class PushToTalkKeyRow extends StatelessWidget {
  const PushToTalkKeyRow({
    super.key,
    required this.current,
    required this.onChanged,
    this.conflictFor,
  });

  final LogicalKeyboardKey current;
  final ValueChanged<LogicalKeyboardKey> onChanged;

  /// What [key] already does, when it cannot also be the push-to-talk key.
  final String? Function(LogicalKeyboardKey key)? conflictFor;

  @override
  Widget build(BuildContext context) => KeyCaptureRow(
    sub: true,
    modifiersAreKeys: true,
    title: 'Key',
    keyCap: pushToTalkKeyName(current),
    semanticName: 'Push-to-talk key',
    onCapture: (captured) {
      final key = captured.key;
      if (!canBindPushToTalk(key)) return 'That key cannot be used.';
      final conflict = conflictFor?.call(key);
      if (conflict != null) return 'Already used for $conflict.';
      onChanged(key);
      return null;
    },
  );
}
