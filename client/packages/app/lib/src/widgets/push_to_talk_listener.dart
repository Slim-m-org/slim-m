// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Desktop push-to-talk: unmutes [VoiceController]'s microphone while the
/// configured key is held, and re-mutes it on release.
///
/// A raw [HardwareKeyboard] handler rather than `home_shell.dart`'s own
/// [CallbackShortcuts], since an activator there fires once on key-down with
/// no matching key-up - hold and release both need to be seen. The handler
/// never consumes an event (always returns `false`), so a physically held
/// key still reaches whatever else is listening, the composer included; the
/// guard against stealing its keystrokes is [composerFocusNodeProvider]
/// itself, checked before every transition, not the choice of key.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../providers/app_lock_controller.dart';
import '../providers/composer_focus.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_settings_controller.dart';

/// Wraps [child] with no visual effect of its own; mount once, high in the
/// tree (`home_shell.dart`'s own root), so push-to-talk works regardless of
/// which screen is on top of a live call.
class PushToTalkListener extends ConsumerStatefulWidget {
  const PushToTalkListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PushToTalkListener> createState() => _PushToTalkListenerState();
}

class _PushToTalkListenerState extends ConsumerState<PushToTalkListener> {
  /// Whether *this* handler opened the microphone for the key currently
  /// down, so a key-up it never started (composer had focus when it went
  /// down, then lost it) is never read as a hold to close.
  bool _held = false;

  @override
  void initState() {
    super.initState();
    if (!isDesktopHost) return;
    // Read once, unawaited: a handler-time first read would otherwise see the pre-load default on this build's very first key event.
    ref.read(voiceSettingsControllerProvider);
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    if (isDesktopHost) HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyUpEvent) return false;
    final settings = ref.read(voiceSettingsControllerProvider);
    if (!settings.pushToTalkEnabled) return false;
    if (event.logicalKey != settings.pushToTalkKey) return false;
    final composerFocused =
        ref.read(composerFocusNodeProvider)?.hasFocus ?? false;

    final controller = ref.read(voiceControllerProvider.notifier);
    if (event is KeyDownEvent) {
      // A locked app takes no input: only a hold already started may still release.
      if (_held || composerFocused || ref.read(appLockControllerProvider)) {
        return false;
      }
      _held = true;
      unawaited(controller.setPushToTalkHeld(true));
    } else if (!_held) {
      return false;
    } else {
      _held = false;
      unawaited(controller.setPushToTalkHeld(false));
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
