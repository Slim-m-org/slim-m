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

import '../providers/call_shortcut_registry.dart';
import '../providers/providers.dart' show apiProvider;
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../providers/voice_settings_controller.dart'
    show voiceSettingsControllerProvider;
import '../widgets/audio_output_sheet.dart';
import '../widgets/camera_source_sheet.dart';
import '../widgets/control_options_menu.dart';
import '../widgets/screen_source_sheet.dart';
import 'call_dock_button.dart';
import 'call_leave_button.dart';

export 'call_dock_button.dart';

class CallControls extends ConsumerStatefulWidget {
  const CallControls({
    super.key,
    required this.controller,
    required this.voice,
    this.showLeave = true,
    this.extraControl,
  });

  final VoiceController controller;

  /// False when the surrounding dock draws leave itself, at its far edge.
  final bool showLeave;

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

  /// The same guard as [_shareRequestInFlight], for [_switchSpeaker].
  bool _speakerSwitchInFlight = false;

  /// Whichever source [_startShare] last resolved a picker's choice to -
  /// preselected (never silently reused) the next time the picker opens, so
  /// report 2's "always goes back to whatever was just chosen" reads as a
  /// highlighted default instead of nothing worth remembering at all. Reset
  /// by nothing on purpose: it only ever changes what a fresh sheet opens
  /// pointing at, never whether one opens.
  String? _lastSourceId;

  /// The deduplicated camera count a picker platform found on mount, once
  /// [_loadCameraCount] resolves; unused on a platform that flips instead
  /// (see [_canSwitchCamera]). Null until then, which reads as "cannot
  /// switch" rather than flashing the button on and immediately off: a
  /// picker platform is exactly the one where duplicate device nodes
  /// (`camera_devices.dart`'s `dedupeCameraDevices`) made an unresolved
  /// count worse than a briefly-late one.
  int? _desktopCameraCount;

  StateController<CallShortcutHandlers?>? _shortcutRegistry;

  /// Mirrors each button's own `onPressed`, so a shortcut can never do
  /// something the matching button could not. `HomeShell` binds the keys.
  late final CallShortcutHandlers _shortcuts = CallShortcutHandlers(
    toggleMute: () => widget.controller.toggleMicrophone(),
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
    if (!widget.controller.canFlipCamera) unawaited(_loadCameraCount());
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

  Future<void> _loadCameraCount() async {
    final devices = await widget.controller.cameraDevices();
    if (!mounted) return;
    setState(() => _desktopCameraCount = devices.length);
  }

  /// Whether there is actually another camera to switch to: a bare flip
  /// needs no device list, since mobile's own OS decides "front" or "back";
  /// a picker platform needs its enumerated, deduplicated count above one,
  /// or the button offers a choice that does not exist.
  bool get _canSwitchCamera =>
      widget.controller.canFlipCamera || (_desktopCameraCount ?? 0) > 1;

  @override
  Widget build(BuildContext context) {
    final voice = widget.voice;
    final shareOptions = _shareOptions(context);
    final pairedAtTouch =
        shareOptions.isNotEmpty && AppTouchTargets.of(context);
    // mainAxisSize.min: this row sizes to its own content now that it has no
    // full-width bar to fill, so whatever floating card embeds it - alone or
    // beside a canvas's own controls - can size itself to match.
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CallDockButton(
          icon: voice.microphoneEnabled ? AppIcons.mic : AppIcons.micOff,
          tooltip: labelWithShortcut(
            voice.microphoneEnabled ? 'Mute' : 'Unmute',
            AppAction.toggleMuteCall,
          ),
          active: voice.microphoneEnabled,
          onPressed: widget.controller.toggleMicrophone,
        ),
        if (widget.controller.supportsAudioOutputSelection) ...[
          const SizedBox(width: AppSpacing.s8),
          CallDockButton(
            icon: AppIcons.speaker,
            tooltip: 'Switch speaker',
            active: false,
            pending: _speakerSwitchInFlight,
            onPressed: () {
              if (_speakerSwitchInFlight) return;
              unawaited(_switchSpeaker(context));
            },
          ),
        ],
        const SizedBox(width: AppSpacing.s8),
        CallDockButton(
          icon: voice.cameraEnabled ? AppIcons.camera : AppIcons.cameraOff,
          tooltip: labelWithShortcut(
            voice.cameraEnabled ? 'Turn off camera' : 'Turn on camera',
            AppAction.toggleCameraCall,
          ),
          active: voice.cameraEnabled,
          pending: voice.cameraPending,
          onPressed: () => unawaited(widget.controller.toggleCamera()),
        ),
        if (voice.cameraEnabled && _canSwitchCamera) ...[
          const SizedBox(width: AppSpacing.s8),
          CallDockButton(
            icon: AppIcons.switchCamera,
            tooltip: 'Switch camera',
            active: false,
            pending: _cameraSwitchInFlight,
            onPressed: () {
              if (_cameraSwitchInFlight) return;
              unawaited(_switchCamera(context));
            },
          ),
        ],
        // At touch density the pair's leading half sits flush right in its hit box, so the gap before it is widened to keep the row's rhythm.
        SizedBox(width: pairedAtTouch ? AppSpacing.s16 : AppSpacing.s8),
        ControlOptionsMenu(
          active: voice.screenSharing,
          optionsLabel: 'Screen share options',
          options: shareOptions,
          child: CallDockButton(
            icon: AppIcons.screenShare,
            tooltip: _shareTooltip(voice),
            active: voice.screenSharing,
            // Pending is its own look, never the active one: the lit
            // button over a share nobody could see was the whole bug.
            pending: voice.awaitingBroadcast,
            onPressed: () {
              if (_shareRequestInFlight) return;
              unawaited(_share(context));
            },
          ),
        ),
        if (widget.extraControl case final extra?) ...[
          const SizedBox(width: AppSpacing.s8),
          extra,
        ],
        if (widget.showLeave) ...[
          const SizedBox(width: AppSpacing.s8),
          CallLeaveButton(controller: widget.controller),
        ],
      ],
    );
    return row;
  }

  static String _shareTooltip(VoiceFlags voice) {
    final shortcut = shortcutSuffix(AppAction.toggleShareCall);
    if (voice.screenSharing) {
      return 'Stop sharing$shortcut';
    }
    if (voice.awaitingBroadcast) {
      return 'Waiting for you to start the broadcast. Tap to cancel.';
    }
    return 'Share a screen$shortcut';
  }

  /// Only while sharing on a platform with a source to switch between; every
  /// entry mirrors something a press or a shortcut could already do.
  List<ControlOption> _shareOptions(BuildContext context) {
    if (!widget.voice.screenSharing ||
        !widget.controller.screenShareNeedsSource) {
      return const [];
    }
    return [
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
      await widget.controller.setScreenShare(false);
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
    await widget.controller.setScreenShare(false);
    if (!context.mounted) return;
    await _startShare(context);
  }

  Future<void> _startShare(BuildContext context) async {
    final controller = widget.controller;
    setState(() => _shareRequestInFlight = true);
    try {
      // The saved ceiling and audio choice, applied directly rather than asked again.
      final settings = ref.read(voiceSettingsControllerProvider);
      final quality = settings.screenShareQuality;

      String? sourceId;
      if (controller.screenShareNeedsSource) {
        // Mandatory: capture cannot find a source nothing asked to list.
        final sources = await controller.screenShareSources();
        if (sources.isEmpty) return;
        // On Linux the portal's own picker is the real choice; see DesktopSources.
        if (sources.length == 1 || !controller.screenShareSourcePickerUseful) {
          sourceId = sources.first.id;
        } else {
          if (!context.mounted) return;
          final chosen = await showScreenSourceSheet(
            context,
            sources,
            selectedId: _lastSourceId,
          );
          if (chosen == null) return;
          sourceId = chosen.id;
        }
      }
      _lastSourceId = sourceId ?? _lastSourceId;
      await controller.setScreenShare(
        true,
        quality: quality,
        sourceId: sourceId,
        includeAudio: settings.screenShareIncludeAudio,
        maxHeight: await _screenShareCeiling(),
      );
    } finally {
      if (mounted) setState(() => _shareRequestInFlight = false);
    }
  }

  /// The space-wide screen-share ceiling, or `null` on any failure to fetch
  /// it, or on a server too old to report one. Read from `GET /version`,
  /// unauthenticated, rather than the MANAGE_SERVER-gated
  /// `GET /space/screen-share` the admin screen uses: every device sharing a
  /// screen has to know this, not only one with an admin bit. This is a
  /// client-advertised courtesy cap, not a security boundary, so a Space
  /// this device cannot reach right now must not be the reason a share never
  /// starts: failing open publishes at the quality already chosen, exactly
  /// what happened before this setting existed.
  Future<int?> _screenShareCeiling() async {
    try {
      final version = await ref.read(apiProvider).version();
      return version.screenShareMaxHeight;
    } catch (_) {
      return null;
    }
  }

  /// Flips on mobile with no picker at all, and asks on desktop, mirroring
  /// [_share]'s own fork between "the OS decides" and "list, then choose".
  Future<void> _switchCamera(BuildContext context) async {
    final controller = widget.controller;
    setState(() => _cameraSwitchInFlight = true);
    try {
      if (controller.canFlipCamera) {
        await controller.flipCamera();
        return;
      }
      if (!controller.cameraNeedsSelection) return;
      final devices = await controller.cameraDevices();
      if (devices.isEmpty) return;
      if (!context.mounted) return;
      // A single-entry list has nothing to choose between, mirroring _share.
      if (devices.length == 1) {
        await controller.selectCameraDevice(devices.first);
        return;
      }
      final chosen = await showCameraDeviceSheet(context, devices);
      if (chosen == null) return;
      await controller.selectCameraDevice(chosen);
    } finally {
      if (mounted) setState(() => _cameraSwitchInFlight = false);
    }
  }

  /// Goes through the same settings notifier the standalone Voice Settings
  /// picker uses, `setAudioOutputDevice` persisting the choice and applying
  /// it live in one call, so the two never drift out of sync with each other.
  Future<void> _switchSpeaker(BuildContext context) async {
    setState(() => _speakerSwitchInFlight = true);
    try {
      final devices = await widget.controller.audioOutputDevices();
      if (!context.mounted) return;
      final selectedId = ref
          .read(voiceSettingsControllerProvider)
          .audioOutputDeviceId;
      final chosen = await showAudioOutputSheet(
        context,
        devices,
        selectedId: selectedId,
      );
      if (chosen == null) return;
      final device = isSystemDefaultAudioDevice(chosen) ? null : chosen;
      await ref
          .read(voiceSettingsControllerProvider.notifier)
          .setAudioOutputDevice(device);
    } finally {
      if (mounted) setState(() => _speakerSwitchInFlight = false);
    }
  }
}
