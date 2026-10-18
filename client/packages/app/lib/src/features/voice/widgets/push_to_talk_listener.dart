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
///
/// This is the in-window source only; OS-level capture feeds the same
/// [PushToTalkGate] from `global_hotkeys_controller.dart`.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../../../providers/app_lifecycle.dart';
import '../providers/global_hotkeys_controller.dart';
import '../providers/push_to_talk_gate.dart';
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

class _PushToTalkListenerState extends ConsumerState<PushToTalkListener>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    if (!isDesktopHost) return;
    // Read once, unawaited: a handler-time first read would otherwise see the pre-load default on this build's very first key event.
    ref.read(voiceSettingsControllerProvider);
    ref.read(globalHotkeysProvider);
    HardwareKeyboard.instance.addHandler(_handleKey);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    if (isDesktopHost) {
      HardwareKeyboard.instance.removeHandler(_handleKey);
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }

  /// The window never sees the key-up once it loses focus; only global capture still can.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    ref.read(pushToTalkGateProvider).release(HoldSource.inWindow);
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyUpEvent) return false;
    final settings = ref.read(voiceSettingsControllerProvider);
    if (!settings.pushToTalkEnabled) return false;
    if (event.logicalKey != settings.pushToTalkKey) return false;
    final gate = ref.read(pushToTalkGateProvider);
    if (event is KeyDownEvent) {
      gate.press(HoldSource.inWindow);
    } else {
      gate.keyWentUp();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(mobileLifecycleHostProvider)) {
      ref.listen<AppLifecycleState>(
        appLifecycleProvider,
        (_, state) => ref
            .read(voiceControllerProvider.notifier)
            .setAppBackgrounded(isBackgroundedOnPhone(state, mobile: true)),
      );
    }
    return widget.child;
  }
}
