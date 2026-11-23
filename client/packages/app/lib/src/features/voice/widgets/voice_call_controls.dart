// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The in-call controls: mute, deafen, camera, screen share and leave.
///
/// Sharing has no quality dialog of its own: the ceiling, and whether to
/// include this device's own audio, are whatever Voice settings already has
/// saved (`voice_settings_screen.dart`'s `voiceSettingsControllerProvider`),
/// applied directly rather than asked again on every share.
///
/// Switching cameras once one is on is a bare flip on mobile
/// (`VoiceController.flipCamera`) and a picker on desktop
/// (`camera_source_sheet.dart`), the same fork `screenShareNeedsSource`
/// already draws for sharing. The switch button only shows on a picker
/// platform once `cameraDevices()` has resolved to more than one
/// deduplicated entry, so one webcam that enumerates several V4L2 nodes never
/// offers a choice there is none of.
///
/// This widget is a bare row, not a bar. The shell, a floating card sized by
/// whoever shows this call, lives in `FloatingDockCard` and
/// `canvas_call_dock.dart`, so a call's controls can sit inside the identical
/// card a canvas's controls do.
///
/// `CallDockButton`, the chip every one of these draws, lives in
/// `call_dock_button.dart` and is re-exported below, so every existing
/// importer of `CallDockButton` from here keeps working unchanged.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'mic_call_button.dart';
import 'muted_talk_watcher.dart';
import 'mic_options_menu.dart';
import '../providers/call_shortcut_registry.dart';
import '../providers/camera_switch.dart';
import '../providers/shortcut_overrides.dart' show shortcutOverridesProvider;
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../providers/voice_settings_controller.dart'
    show voiceSettingsControllerProvider;
import 'camera_source_sheet.dart';
import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart' show ControlOptionEntry;
import 'call_share_flow.dart';
import 'call_availability.dart';
import 'call_device_options.dart';
import 'call_dock_hint.dart';
import '../providers/call_dock_hint.dart' show DockHintTarget;
import 'call_dock_button.dart';
import 'share_options_menu.dart';
import 'screen_stamps_received_sheet.dart';
import '../../canvas/providers/armed_stamp.dart'
    show canvasStampsSupportedProvider;
import 'captions_button.dart';
import 'soundboard_button.dart';
import '../../../widgets/shortcut_label.dart';

export 'call_dock_button.dart';

class CallControls extends ConsumerStatefulWidget {
  const CallControls({
    super.key,
    required this.controller,
    required this.voice,
    this.extraControl,
    this.tight = false,
    this.spilledOnly = false,
    this.menuExtras = const [],
    this.hints = true,
    this.ownsShortcuts = true,
  });

  final VoiceController controller;

  /// False for a second copy laid over the first, such as a full screen video's dock, which must not take the call shortcuts from it.
  final bool ownsShortcuts;

  /// For a card too narrow to hold them all: camera switch, soundboard, captions and the extra control leave this row, and the mic's caret gives way to a long press.
  final bool tight;

  /// Draws only the controls a [tight] row leaves out, as a card row of their own above it.
  final bool spilledOnly;

  /// False in a dock with tools directly above, which a hint bubble would cover.
  final bool hints;

  /// Controls folded into the mic menu so the row stays one line.
  final List<ControlOptionEntry> menuExtras;

  /// One more control, drawn straight after share - the canvas toggle.
  final Widget? extraControl;

  /// Only the flags half of the call: this row never has any use for the
  /// roster, and typing it this way keeps a future caller from threading it
  /// back in the way `railVoiceToggleButtons` used to.
  final VoiceFlags voice;

  @override
  ConsumerState<CallControls> createState() => _CallControlsState();
}

class _CallControlsState extends ConsumerState<CallControls> {
  late final _share = CallShareFlow(
    ref: ref,
    controller: () => widget.controller,
    voice: () => widget.voice,
    mounted: () => mounted,
    changed: setState,
  );

  /// The same guard as [CallShareFlow]'s, for [_switchCamera].
  bool _cameraSwitchInFlight = false;

  StateController<CallShortcutHandlers?>? _shortcutRegistry;

  /// Mirrors each button's own `onPressed`, so a shortcut can never do
  /// something the matching button could not. `HomeShell` binds the keys.
  late final CallShortcutHandlers _shortcuts = CallShortcutHandlers(
    toggleMute: () => widget.controller.toggleMicrophone(),
    toggleDeafen: () => unawaited(widget.controller.toggleDeafen()),
    toggleCamera: () => unawaited(widget.controller.toggleCamera()),
    toggleShare: () => _share.toggle(context),
    leave: () => widget.controller.leave(),
  );

  @override
  void initState() {
    super.initState();
    if (isDesktopHost && widget.ownsShortcuts) {
      // A provider write is a build-time mutation when this mounts mid-build, so it waits a frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final registry = ref.read(callShortcutHandlersProvider.notifier);
        registry.state = _shortcuts;
        _shortcutRegistry = registry;
      });
    }
  }

  @override
  void dispose() {
    final registry = _shortcutRegistry;
    final shortcuts = _shortcuts;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (registry != null && registry.mounted && registry.state == shortcuts) {
        registry.state = null;
      }
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final voice = widget.voice;
    // Tooltips name the shortcut, so a remap redraws them.
    ref.watch(shortcutOverridesProvider);
    final touch = AppTouchTargets.of(context);
    final shareOptions = _shareOptions(context);
    final listenOnly = listenOnlyReason(ref, voice);
    // Touch density is the width-derived compact test; that row has no room for a caret only quality asked for.
    final showCaret =
        !touch || (voice.screenSharing && _canSwitchSource && !widget.tight);
    final pairedAtTouch = showCaret && touch;
    // A tight row has no width for the mic's caret either; a long press opens its menu instead.
    final micCaret = !touch && !widget.tight;
    // mainAxisSize.min: this row sizes to its own content now that it has no
    // full-width bar to fill, so whatever floating card embeds it - alone or
    // beside a canvas's own controls - can size itself to match.
    final switchCamera =
        voice.cameraEnabled && canSwitchCamera(ref, widget.controller)
        ? _switchCameraButton(context)
        : null;
    final extra = widget.extraControl;
    final soundboard = canUseSoundboard(ref, voice.channelId)
        ? SoundboardButton(channelId: voice.channelId!)
        : null;
    final captions = canUseCaptions(ref, voice.channelId)
        ? const CaptionsButton()
        : null;
    if (widget.spilledOnly) {
      final spilled = [?switchCamera, ?soundboard, ?captions, ?extra];
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < spilled.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.s8),
            spilled[i],
          ],
        ],
      );
    }
    final primary = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _micGroup(voice, listenOnly, micCaret: micCaret),
        const SizedBox(width: AppSpacing.s8),
        _deafenButton(voice),
        const SizedBox(width: AppSpacing.s8),
        CameraOptionsMenu(
          controller: widget.controller,
          cameraOn: voice.cameraEnabled,
          active: voice.cameraEnabled && listenOnly == null,
          showCaret: micCaret,
          child: _cameraButton(voice, listenOnly, holdOpens: !micCaret),
        ),
        if (switchCamera != null && !widget.tight) ...[
          const SizedBox(width: AppSpacing.s8),
          switchCamera,
        ],
        // At touch density the pair's leading half sits flush right in its hit box, so the gap before it is widened to keep the row's rhythm.
        SizedBox(width: pairedAtTouch ? AppSpacing.s16 : AppSpacing.s8),
        DockHintAnchor(
          target: DockHintTarget.share,
          enabled: widget.hints && listenOnly == null && !showCaret,
          child: ControlOptionsMenu(
            active: voice.screenSharing,
            optionsLabel: 'Screen share options',
            options: shareOptions,
            menuWidth: callMenuWidth,
            showCaret: showCaret,
            child: _shareButton(context, voice, showCaret: showCaret),
          ),
        ),
        if (soundboard != null && !widget.tight) ...[
          const SizedBox(width: AppSpacing.s8),
          soundboard,
        ],
        if (captions != null && !widget.tight) ...[
          const SizedBox(width: AppSpacing.s8),
          captions,
        ],
        if (extra != null && !widget.tight) ...[
          const SizedBox(width: AppSpacing.s8),
          extra,
        ],
      ],
    );
    return primary;
  }

  /// The mic button with its menu, its one-time hint and the talking-while-muted cue.
  Widget _micGroup(
    VoiceFlags voice,
    String? listenOnly, {
    required bool micCaret,
  }) {
    final pushToTalk = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.pushToTalkEnabled),
    );
    return DockHintAnchor(
      target: DockHintTarget.mic,
      enabled: widget.hints && listenOnly == null,
      child: MutedTalkWatcher(
        watching:
            widget.hints &&
            !voice.microphoneEnabled &&
            listenOnly == null &&
            !pushToTalk,
        child: MicOptionsMenu(
          showCaret: micCaret,
          extraOptions: widget.menuExtras,
          destructive: micCallDestructive(ref, voice, listenOnly),
          child: MicCallButton(
            voice: voice,
            listenOnly: listenOnly,
            holdOpensOptions: !micCaret,
            controller: widget.controller,
          ),
        ),
      ),
    );
  }

  /// One click stops all incoming audio, the same toggle as the user panel's headphones; the speaker list is in the mic menu.
  Widget _deafenButton(VoiceFlags voice) {
    return CallDockButton(
      icon: voice.deafened ? AppIcons.headphonesOff : AppIcons.headphones,
      tooltip: labelWithShortcut(
        voice.deafened ? 'Undeafen' : 'Deafen',
        AppAction.toggleDeafenCall,
      ),
      active: false,
      destructive: voice.deafened,
      onPressed: () => unawaited(widget.controller.toggleDeafen()),
    );
  }

  Widget _cameraButton(
    VoiceFlags voice,
    String? listenOnly, {
    required bool holdOpens,
  }) {
    return CallDockButton(
      holdOpensOptions: holdOpens,
      icon: voice.cameraEnabled && listenOnly == null
          ? AppIcons.camera
          : AppIcons.cameraOff,
      tooltip:
          listenOnly ??
          labelWithShortcut(
            voice.cameraEnabled ? 'Turn off camera' : 'Turn on camera',
            AppAction.toggleCameraCall,
          ),
      active: voice.cameraEnabled && listenOnly == null,
      unavailable: listenOnly != null,
      pending: voice.cameraPending,
      onPressed: () => unawaited(widget.controller.toggleCamera()),
    );
  }

  Widget _switchCameraButton(BuildContext context) {
    return CallDockButton(
      icon: AppIcons.switchCamera,
      tooltip: 'Switch camera',
      active: false,
      pending: _cameraSwitchInFlight,
      onPressed: () {
        if (_cameraSwitchInFlight) return;
        unawaited(_switchCamera(context));
      },
    );
  }

  Widget _shareButton(
    BuildContext context,
    VoiceFlags voice, {
    required bool showCaret,
  }) {
    return CallDockButton(
      key: _share.buttonKey,
      icon: AppIcons.screenShare,
      tooltip: _shareTooltip(voice),
      active: voice.screenSharing,
      holdOpensOptions: !showCaret,
      // Pending is its own look, never the active one: the lit
      // button over a share nobody could see was the whole bug.
      pending: voice.awaitingBroadcast,
      onPressed: () => _share.toggle(context),
    );
  }

  static String _shareTooltip(VoiceFlags voice) {
    final shortcut = shortcutSuffix(AppAction.toggleShareCall);
    if (voice.screenSharing) {
      return 'You are sharing your screen. Stop sharing$shortcut';
    }
    if (voice.awaitingBroadcast) {
      return 'Waiting for you to start the broadcast. Tap to cancel.';
    }
    return 'Share a screen$shortcut';
  }

  bool get _canSwitchSource => widget.controller.video.screenShareNeedsSource;

  bool get _stampsKept => ref.read(canvasStampsSupportedProvider);

  List<ControlOptionEntry> _shareOptions(BuildContext context) =>
      shareMenuEntries(
        ref,
        voice: widget.voice,
        controller: widget.controller,
        current: _share.lastSource,
        actions: ShareMenuActions(
          onStop: () => _share.toggle(context),
          onChangeSource: () => _share.changeSource(context),
          onPickSource: (source) => _share.pick(context, source),
          onPicturesOnScreen: _stampsKept
              ? () => unawaited(
                  showScreenStampsReceived(
                    _share.buttonKey.currentContext ?? context,
                    above: true,
                  ),
                )
              : null,
        ),
      );

  /// Flips on mobile with no picker at all, and asks on desktop, mirroring
  /// `pickShareSource`'s fork between "the OS decides" and "list, then choose".
  Future<void> _switchCamera(BuildContext context) async {
    final controller = widget.controller;
    final settings = ref.read(voiceSettingsControllerProvider.notifier);
    setState(() => _cameraSwitchInFlight = true);
    try {
      if (controller.video.canFlipCamera) {
        await controller.video.flipCamera();
        return;
      }
      if (!controller.video.cameraNeedsSelection) return;
      final devices = await controller.video.cameraDevices();
      if (devices.isEmpty) return;
      if (!context.mounted) return;
      // One device has nothing to choose between, mirroring pickShareSource.
      if (devices.length == 1) {
        await pickCameraDevice(controller.video, settings, devices.first);
        return;
      }
      final chosen = await showCameraDeviceSheet(context, devices);
      if (chosen == null) return;
      await pickCameraDevice(controller.video, settings, chosen);
    } finally {
      if (mounted) setState(() => _cameraSwitchInFlight = false);
    }
  }
}
