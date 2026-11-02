// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock's device options: the camera button's menu (device,
/// resolution, mirror) and the speaker list the mic menu carries.
///
/// Each pick is written through the notifier Voice settings uses, so the dock
/// and the settings pane cannot disagree. The speaker list is absent where the
/// platform cannot switch output (iOS and the web), never disabled.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart'
    show AudioDevice, CameraDevice, CameraQuality, resolveAudioDevice;

import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart' show ControlOptionEntry;
import '../providers/camera_switch.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_settings_controller.dart';
import 'video_quality_labels.dart';

/// Wide enough for a device name; the default menu width truncates them.
const deviceMenuWidth = 280.0;

/// A pick-one list of audio devices under [heading], with the system default first.
List<ControlOptionEntry> audioDeviceOptions({
  required String heading,
  required List<AudioDevice> devices,
  required String? selectedId,
  required Future<void> Function(AudioDevice?) onPick,
}) {
  final resolved = resolveAudioDevice(devices, selectedId);
  return [
    ControlOptionHeading(heading),
    ControlOption(
      label: 'System default',
      selected: resolved == null,
      onSelected: () => unawaited(onPick(null)),
    ),
    for (final device in devices)
      ControlOption(
        label: device.label.isEmpty ? 'Unnamed device' : device.label,
        selected: device.id == resolved?.id,
        onSelected: () => unawaited(onPick(device)),
      ),
  ];
}

/// What a pick in the camera menu does.
class CameraMenuActions {
  const CameraMenuActions({
    required this.onQuality,
    required this.onMirror,
    required this.onDevice,
    required this.onFlip,
  });

  final ValueChanged<CameraQuality> onQuality;
  final ValueChanged<bool> onMirror;
  final ValueChanged<CameraDevice> onDevice;
  final VoidCallback onFlip;
}

/// What the camera menu offers, from plain values so a test can read it without a call.
List<ControlOptionEntry> cameraMenuEntries({
  required CameraQuality quality,
  required bool mirror,
  required List<CameraDevice> devices,
  required bool canFlip,
  required CameraMenuActions actions,
}) {
  return [
    if (canFlip)
      ControlOption(
        label: 'Flip camera',
        icon: AppIcons.switchCamera,
        onSelected: actions.onFlip,
      ),
    if (devices.isNotEmpty) ...[
      const ControlOptionHeading('Switch camera'),
      for (final device in devices)
        ControlOption(
          label: device.label.isEmpty ? 'Unnamed camera' : device.label,
          onSelected: () => actions.onDevice(device),
        ),
    ],
    const ControlOptionHeading('Resolution'),
    for (final value in CameraQuality.values)
      ControlOption(
        label: cameraQualityLabel(value),
        selected: value == quality,
        onSelected: () => actions.onQuality(value),
      ),
    const ControlOptionHeading('Preview'),
    ControlOption(
      label: 'Mirror my view',
      selected: mirror,
      onSelected: () => actions.onMirror(!mirror),
    ),
  ];
}

/// [child] with the camera options on a caret, or on a long press when [showCaret] is false.
class CameraOptionsMenu extends ConsumerWidget {
  const CameraOptionsMenu({
    super.key,
    required this.controller,
    required this.cameraOn,
    required this.showCaret,
    required this.child,
    this.active = false,
  });

  final VoiceController controller;

  /// Only a running camera has a device to switch.
  final bool cameraOn;
  final bool showCaret;
  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(voiceSettingsControllerProvider);
    final notifier = ref.read(voiceSettingsControllerProvider.notifier);
    final video = controller.video;
    final devices = cameraOn && video.cameraNeedsSelection
        ? ref.watch(cameraDeviceListProvider(controller)).valueOrNull ??
              const <CameraDevice>[]
        : const <CameraDevice>[];
    return ControlOptionsMenu(
      optionsLabel: 'Camera options',
      active: active,
      showCaret: showCaret,
      menuWidth: deviceMenuWidth,
      options: cameraMenuEntries(
        quality: settings.cameraQuality,
        mirror: settings.mirrorSelfView,
        devices: devices.length > 1 ? devices : const [],
        canFlip: cameraOn && video.canFlipCamera,
        actions: CameraMenuActions(
          onQuality: (value) => unawaited(notifier.setCameraQuality(value)),
          onMirror: (value) => unawaited(notifier.setMirrorSelfView(value)),
          onDevice: (device) => unawaited(video.selectCameraDevice(device)),
          onFlip: () => unawaited(video.flipCamera()),
        ),
      ),
      child: child,
    );
  }
}
