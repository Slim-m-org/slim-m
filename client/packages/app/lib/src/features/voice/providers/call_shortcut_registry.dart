// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the in-call shortcuts do, for whichever call control row is on screen.
///
/// `HomeShell` binds the keys so they work from anywhere focus can be (the
/// composer beside a call included), but it holds no reference to the row's
/// handlers, which need its state and context. The mounted `CallControls`
/// registers them here, the same shape `composerFocusNodeProvider` gives the
/// focus-composer shortcut.
library;

import 'dart:ui' show VoidCallback;

import 'package:flutter_riverpod/flutter_riverpod.dart';

class CallShortcutHandlers {
  const CallShortcutHandlers({
    required this.toggleMute,
    required this.toggleCamera,
    required this.toggleShare,
    required this.leave,
  });

  final VoidCallback toggleMute;
  final VoidCallback toggleCamera;
  final VoidCallback toggleShare;
  final VoidCallback leave;
}

final callShortcutHandlersProvider = StateProvider<CallShortcutHandlers?>(
  (ref) => null,
);
