// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock's device options: the camera button's menu (device, quality,
/// mirror) and the audio device lists the mic menu carries.
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

import '../../../widgets/control_menu_entries.dart';
import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart' show ControlOptionEntry;
import '../providers/camera_switch.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_settings_controller.dart';
import '../providers/voice_video_controls.dart';
import 'camera_menu_preview.dart';
import 'video_quality_labels.dart';

/// One width for the microphone, camera and share menus, wide enough for a device name and four noise suppression segments.
const callMenuWidth = 324.0;

/// What a device row shows as the current choice.
String audioDeviceValue(List<AudioDevice> devices, String? selectedId) {
  final resolved = resolveAudioDevice(devices, selectedId);
  if (resolved == null) return 'System default';
  return resolved.label.isEmpty ? 'Unnamed device' : resolved.label;
}

/// A pick-one list of audio devices, with the system default first.
List<ControlOption> audioDeviceOptions({
  required List<AudioDevice> devices,
  required String? selectedId,
  required Future<void> Function(AudioDevice?) onPick,
}) {
  final resolved = resolveAudioDevice(devices, selectedId);
  return [
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

/// Switches to [device], and remembers it only once the switch worked.
Future<void> pickCameraDevice(
  VoiceVideoControls video,
  VoiceSettingsController notifier,
  CameraDevice device,
) async {
  if (await video.selectCameraDevice(device)) {
    await notifier.setCameraDeviceId(device.id);
  }
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
  String? chosenDeviceId,
  WidgetBuilder? preview,
}) {
  final chosen = devices.where((d) => d.id == chosenDeviceId).firstOrNull;
  const values = CameraQuality.values;
  return joinMenuGroups([
    [
      if (devices.isNotEmpty)
        ControlSubmenu(
          label: 'Camera',
          icon: AppIcons.camera,
          value: chosen == null ? 'Default' : cameraDeviceName(chosen),
          options: [
            for (final device in devices)
              ControlOption(
                label: cameraDeviceName(device),
                selected: device.id == chosenDeviceId,
                onSelected: () => actions.onDevice(device),
              ),
          ],
        ),
      if (preview != null) ControlInline(preview),
    ],
    [
      ControlSegmented(
        label: 'Quality',
        options: [
          for (final value in values)
            AppSegmentedOption(label: cameraQualityLabel(value)),
        ],
        selectedIndex: values.indexOf(quality),
        onSelected: (i) => actions.onQuality(values[i]),
      ),
    ],
    [
      ControlSwitch(
        label: 'Mirror my view',
        value: mirror,
        onChanged: actions.onMirror,
      ),
    ],
    [
      if (canFlip)
        ControlOption(
          label: 'Flip camera',
          icon: AppIcons.switchCamera,
          onSelected: actions.onFlip,
        ),
    ],
  ]);
}

/// A camera's name for a list, since some report none.
String cameraDeviceName(CameraDevice device) =>
    device.label.isEmpty ? 'Unnamed camera' : device.label;

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
      menuWidth: callMenuWidth,
      options: cameraMenuEntries(
        quality: settings.cameraQuality,
        mirror: settings.mirrorSelfView,
        devices: devices.length > 1 ? devices : const [],
        canFlip: cameraOn && video.canFlipCamera,
        chosenDeviceId: settings.cameraDeviceId,
        preview: cameraOn
            ? (_) => CameraMenuPreview(controller: controller)
            : null,
        actions: CameraMenuActions(
          onQuality: (value) => unawaited(notifier.setCameraQuality(value)),
          onMirror: (value) => unawaited(notifier.setMirrorSelfView(value)),
          onDevice: (device) =>
              unawaited(pickCameraDevice(video, notifier, device)),
          onFlip: () => unawaited(video.flipCamera()),
        ),
      ),
      child: child,
    );
  }
}
