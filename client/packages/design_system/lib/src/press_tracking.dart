// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The finger-down flag the tappable controls share.
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Tracks whether a finger is down on the control: a phone has no hover, so
/// this is the only sign a tap landed before its action runs.
///
/// A control disabled mid-press loses its tap recognizer in the build phase,
/// which cancels the press there, where setState is not allowed; the write is
/// deferred a frame in that case.
mixin PressTracking<T extends StatefulWidget> on State<T> {
  bool _pressed = false;

  bool get pressed => _pressed;

  void setPressed(bool value) {
    if (_pressed == value) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _pressed = value);
      });
      return;
    }
    setState(() => _pressed = value);
  }
}
