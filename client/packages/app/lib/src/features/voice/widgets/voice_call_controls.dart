// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The in-call controls: mute, camera, screen share and leave.
///
/// Sharing has no quality dialog of its own: the ceiling, and whether to
/// include this device's own audio, are whatever Voice settings already has
/// saved (`voice_settings_screen.dart`'s `voiceSettingsControllerProvider`),
/// applied directly rather than asked again on every share, which is what
/// the owner reported as the quality setting "not mattering".
///
/// The camera button is the same row as hang up, which is where the owner
/// asked for it: no separate toggle lived anywhere in a call before this.
/// Switching cameras once one is on is a bare flip on mobile
/// (`VoiceController.flipCamera`, no device list to show) and a picker on
/// desktop (`camera_source_sheet.dart`), the same fork `screenShareNeedsSource`
/// already draws for sharing. The switch button itself only shows on a
/// picker platform once `cameraDevices()` has resolved to more than one
/// deduplicated entry, so a desktop with one physical webcam that happens to
/// enumerate several V4L2 nodes never offers a choice there is none of.
///
/// This widget is a bare row now, not a bar: it used to paint its own
/// full-width, edge-anchored strip, which is exactly what made opening the
/// canvas make it disappear outright (`ConversationPane` swaps the whole
/// pane, controls included) rather than merely getting out of the way. The
/// shell - a floating card, positioned and sized by whoever is showing this
/// call right now - lives in `FloatingDockCard` and `canvas_call_dock.dart`
/// instead, so a call's controls can sit inside the identical card a
/// canvas's controls do, combined, whenever both are relevant at once.
///
/// Its own file because `voice_screen.dart` was over this repo's hard file
/// limit, and this row is the one part of that screen with no dependency on
/// which channel is being looked at.
///
/// `CallDockButton`, the chip every one of these draws, moved to its own
/// file (`call_dock_button.dart`, re-exported below) once the keyboard
/// shortcuts and the speaker quick-switch pushed this one past the same
/// limit again; every existing importer of `CallDockButton` from here keeps
/// working unchanged.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import 'mic_call_button.dart';
import 'mic_options_menu.dart';
import '../providers/call_shortcut_registry.dart';
import '../providers/camera_switch.dart';
import '../providers/shortcut_overrides.dart' show shortcutOverridesProvider;
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../../screen_overlay/providers/screen_overlay_controller.dart'
    show screenOverlaySupportedProvider;
import '../providers/voice_state.dart' show ShareAudio;
import '../providers/voice_settings_controller.dart'
    show voiceSettingsControllerProvider;
import 'camera_source_sheet.dart';
import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart' show ControlOptionEntry;
import 'screen_share_start.dart';
import 'call_availability.dart';
import 'call_dock_button.dart';
import 'call_quality_options.dart';
import 'call_leave_button.dart' show labelWithShortcut, shortcutSuffix;

export 'call_dock_button.dart';

class CallControls extends ConsumerStatefulWidget {
  const CallControls({
    super.key,
    required this.controller,
    required this.voice,
    this.extraControl,
    this.tight = false,
    this.menuExtras = const [],
  });

  final VoiceController controller;

  /// Camera switch and the extra control wrap to a second row, and the mic's caret gives way to a long press, for a card too narrow to hold them all.
  final bool tight;

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
  /// Guards a fast double-tap from opening two source-selection sheets: the
  /// enumeration and its own sheet run entirely inside [_share], before
  /// [VoiceController.setScreenShare] is ever called, so nothing further down
  /// the stack can catch a re-entrant tap.
  bool _shareRequestInFlight = false;

  /// The same guard as [_shareRequestInFlight], for [_switchCamera].
  bool _cameraSwitchInFlight = false;

  /// Whichever source [_startShare] last resolved a picker's choice to -
  /// preselected (never silently reused) the next time the picker opens, so
  /// report 2's "always goes back to whatever was just chosen" reads as a
  /// highlighted default instead of nothing worth remembering at all. Reset
  /// by nothing on purpose: it only ever changes what a fresh sheet opens
  /// pointing at, never whether one opens.
  String? _lastSourceId;

  StateController<CallShortcutHandlers?>? _shortcutRegistry;

  /// Mirrors each button's own `onPressed`, so a shortcut can never do
  /// something the matching button could not. `HomeShell` binds the keys.
  late final CallShortcutHandlers _shortcuts = CallShortcutHandlers(
    toggleMute: () => widget.controller.toggleMicrophone(),
    toggleDeafen: () => unawaited(widget.controller.toggleDeafen()),
    toggleCamera: () => unawaited(widget.controller.toggleCamera()),
    toggleShare: () {
      if (_shareRequestInFlight) return;
      unawaited(_share(context));
    },
    leave: () => widget.controller.leave(),
  );

  @override
  void initState() {
    super.initState();
    if (isDesktopHost) {
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
    final showCaret = !touch || (voice.screenSharing && _canSwitchSource);
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
    final primary = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MicOptionsMenu(
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
        const SizedBox(width: AppSpacing.s8),
        _deafenButton(voice),
        const SizedBox(width: AppSpacing.s8),
        _cameraButton(voice, listenOnly),
        if (switchCamera != null && !widget.tight) ...[
          const SizedBox(width: AppSpacing.s8),
          switchCamera,
        ],
        // At touch density the pair's leading half sits flush right in its hit box, so the gap before it is widened to keep the row's rhythm.
        SizedBox(width: pairedAtTouch ? AppSpacing.s16 : AppSpacing.s8),
        ControlOptionsMenu(
          active: voice.screenSharing,
          optionsLabel: 'Screen share options',
          options: shareOptions,
          showCaret: showCaret,
          child: _shareButton(context, voice, showCaret: showCaret),
        ),
        if (extra != null && !widget.tight) ...[
          const SizedBox(width: AppSpacing.s8),
          extra,
        ],
      ],
    );
    if (!widget.tight) return primary;
    final spilled = [?switchCamera, ?extra];
    return _spillColumn(primary, spilled);
  }

  Widget _spillColumn(Widget primary, List<Widget> spilled) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        primary,
        if (spilled.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < spilled.length; i++) ...[
                if (i > 0) const SizedBox(width: AppSpacing.s8),
                spilled[i],
              ],
            ],
          ),
        ],
      ],
    );
  }

  /// One click stops all incoming audio, the same toggle as the user panel's headphones; output devices stay in Voice settings.
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

  Widget _cameraButton(VoiceFlags voice, String? listenOnly) {
    return CallDockButton(
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
      icon: AppIcons.screenShare,
      tooltip: _shareTooltip(voice),
      active: voice.screenSharing,
      holdOpensOptions: !showCaret,
      // Pending is its own look, never the active one: the lit
      // button over a share nobody could see was the whole bug.
      pending: voice.awaitingBroadcast,
      onPressed: () {
        if (_shareRequestInFlight) return;
        unawaited(_share(context));
      },
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

  /// Switching and stopping only while sharing on a platform with a source to
  /// switch between; the quality groups are always there, since they set the
  /// next share, camera start and what you watch. One menu carries all three
  /// so a phone's dock keeps a single caret, or none: a compact window opens
  /// them by long press, since its row has no width to spare.
  List<ControlOptionEntry> _shareOptions(BuildContext context) {
    return [
      if (widget.voice.screenSharing && _canSwitchSource) ...[
        ControlOption(
          label: 'Switch screen...',
          icon: AppIcons.screenShareSwitch,
          onSelected: () {
            if (_shareRequestInFlight) return;
            unawaited(_changeSource(context));
          },
        ),
        ControlOption(
          label: 'Stop sharing',
          icon: AppIcons.screenShareStop,
          tone: AppMenuItemTone.danger,
          onSelected: () {
            if (_shareRequestInFlight) return;
            unawaited(_share(context));
          },
        ),
      ],
      if (widget.voice.shareAudio != ShareAudio.none)
        ControlOption(
          label: widget.voice.shareAudio == ShareAudio.on
              ? 'Mute shared audio'
              : 'Unmute shared audio',
          icon: widget.voice.shareAudio == ShareAudio.on
              ? AppIcons.speakerOff
              : AppIcons.speaker,
          onSelected: () => unawaited(
            widget.controller.share.setScreenShareAudioOn(
              widget.voice.shareAudio == ShareAudio.muted,
            ),
          ),
        ),
      if (ref.watch(screenOverlaySupportedProvider))
        ControlOption(
          label: 'Viewers draw on my screen',
          icon: AppIcons.pen,
          selected: ref
              .watch(voiceSettingsControllerProvider)
              .screenShareAllowAnnotations,
          onSelected: () => unawaited(
            ref
                .read(voiceSettingsControllerProvider.notifier)
                .setScreenShareAllowAnnotations(
                  !ref
                      .read(voiceSettingsControllerProvider)
                      .screenShareAllowAnnotations,
                ),
          ),
        ),
      ...videoQualityOptions(ref),
    ];
  }

  Future<void> _share(BuildContext context) async {
    final voice = widget.voice;
    // Cancelling a request that never became a broadcast goes down the same
    // path as stopping a live one, which is also what ends the recording.
    // A live share stops here too - [_changeSource] is the options menu's
    // route to switching source, so this bare tap never has to guess which
    // of the two a person meant.
    if (voice.screenSharing || voice.awaitingBroadcast) {
      await widget.controller.share.setScreenShare(false);
      return;
    }
    await _startShare(context);
  }

  /// Report 2 in the backlog channel, in the owner's own words: "after
  /// choosing a screen share screen there is never an option to choose a
  /// different one while in the same call" - reached from the share button's
  /// options caret (or a long press) while it is active, since a bare tap
  /// there is already spoken for by stop. Stops the running share
  /// outright before asking for a new source, rather than trusting
  /// [VoiceSession.setScreenShareEnabled] to hot-swap a capture already in
  /// flight - the same two-step "stop, then start" a person switching
  /// sources by hand would do themselves.
  Future<void> _changeSource(BuildContext context) async {
    if (!widget.voice.screenSharing) return;
    if (!widget.controller.video.screenShareSourcePickerUseful) {
      await widget.controller.share.setScreenShare(false);
      if (!context.mounted) return;
      await _startShare(context);
      return;
    }
    await _startShare(context, stopFirst: true);
  }

  Future<void> _startShare(
    BuildContext context, {
    bool stopFirst = false,
  }) async {
    final controller = widget.controller;
    setState(() => _shareRequestInFlight = true);
    try {
      // The saved ceiling and audio choice, applied directly rather than asked again.
      final settings = ref.read(voiceSettingsControllerProvider);
      final quality = settings.screenShareQuality;

      final pick = await pickShareSource(
        context,
        controller,
        lastSourceId: _lastSourceId,
      );
      if (!pick.proceed) return;
      final sourceId = pick.id;
      // The call can end while a picker or the source list is open.
      final voice = widget.voice;
      if (!mounted ||
          !(voice.state == VoiceSessionState.connected || voice.rejoining)) {
        return;
      }
      _lastSourceId = sourceId ?? _lastSourceId;
      if (stopFirst) await controller.share.setScreenShare(false);
      await controller.share.setScreenShare(
        true,
        quality: quality,
        sourceId: sourceId,
        includeAudio: settings.screenShareIncludeAudio,
        maxHeight: await screenShareCeiling(ref),
        source: pick.source,
      );
    } finally {
      if (mounted) setState(() => _shareRequestInFlight = false);
    }
  }

  /// Flips on mobile with no picker at all, and asks on desktop, mirroring
  /// [_share]'s own fork between "the OS decides" and "list, then choose".
  Future<void> _switchCamera(BuildContext context) async {
    final controller = widget.controller;
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
      // A single-entry list has nothing to choose between, mirroring _share.
      if (devices.length == 1) {
        await controller.video.selectCameraDevice(devices.first);
        return;
      }
      final chosen = await showCameraDeviceSheet(context, devices);
      if (chosen == null) return;
      await controller.video.selectCameraDevice(chosen);
    } finally {
      if (mounted) setState(() => _cameraSwitchInFlight = false);
    }
  }
}
