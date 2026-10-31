// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock's microphone options: input device, noise suppression and
/// the input toggles, all backed by the providers Voice settings already uses.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart' show AudioDevice, resolveAudioDevice;

import '../../../routing/routes.dart';
import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart' show ControlOptionEntry;
import '../providers/noise_suppression.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_settings_controller.dart';

/// Wide enough for a device name; the default menu width truncates them.
const micMenuWidth = 280.0;

/// The voice settings pane the menu's last row opens.
const voiceSettingsPane = 'voice';

const _labels = {
  NoiseSuppressionChoice.spaceDefault: 'Space default',
  NoiseSuppressionChoice.standard: 'Standard',
  NoiseSuppressionChoice.strong: 'Strong',
  NoiseSuppressionChoice.strongest: 'Strongest',
};

class MicOptionsMenu extends ConsumerStatefulWidget {
  const MicOptionsMenu({
    super.key,
    required this.showCaret,
    required this.child,
    this.extraOptions = const [],
    this.destructive = false,
  });

  final bool showCaret;

  /// True while the mic is muted or lost, so the caret shares the button's danger outline.
  final bool destructive;
  final Widget child;

  /// Dock controls that have no slot of their own on a narrow dock ride at the end of this menu.
  final List<ControlOptionEntry> extraOptions;

  @override
  ConsumerState<MicOptionsMenu> createState() => _MicOptionsMenuState();
}

class _MicOptionsMenuState extends ConsumerState<MicOptionsMenu> {
  List<AudioDevice> _inputs = const [];
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _changes = ref
        .read(voiceControllerProvider.notifier)
        .devices
        .audioDeviceChanges
        .listen((_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  Future<void> _refresh() async {
    final inputs = await ref
        .read(voiceControllerProvider.notifier)
        .devices
        .audioInputDevices();
    if (mounted) setState(() => _inputs = inputs);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(voiceSettingsControllerProvider);
    final noise = ref.watch(noiseSuppressionProvider);
    final controller = ref.read(voiceControllerProvider.notifier);
    final notifier = ref.read(voiceSettingsControllerProvider.notifier);
    return ControlOptionsMenu(
      optionsLabel: 'Microphone options',
      showCaret: widget.showCaret,
      destructive: widget.destructive,
      menuWidth: micMenuWidth,
      options: [
        ..._deviceOptions(
          supported: controller.devices.supportsAudioInputSelection,
          selectedId: settings.audioInputDeviceId,
          onPick: notifier.setAudioInputDevice,
        ),
        if (controller.input.supportsInputGate) ...[
          const ControlOptionHeading('Noise suppression'),
          for (final choice in NoiseSuppressionChoice.offered(
            supported: ref.watch(strongestSupportedProvider),
          ))
            ControlOption(
              label: _labels[choice]!,
              selected: choice == noise,
              onSelected: () => unawaited(
                ref.read(noiseSuppressionProvider.notifier).set(choice),
              ),
            ),
          const ControlOptionHeading('Input'),
          ControlOption(
            label: 'Automatic sensitivity',
            selected: settings.inputThresholdAuto,
            onSelected: () => unawaited(
              notifier.setInputThresholdAuto(!settings.inputThresholdAuto),
            ),
          ),
          ControlOption(
            label: 'Even out loud sounds',
            selected: settings.evenOutLoudSounds,
            onSelected: () => unawaited(
              notifier.setEvenOutLoudSounds(!settings.evenOutLoudSounds),
            ),
          ),
        ],
        ...widget.extraOptions,
        ControlOption(
          label: 'Voice settings',
          icon: AppIcons.settings,
          onSelected: () => unawaited(
            GoRouter.of(context).push(
              '${Routes.personalSettings}?$settingsPaneQuery=$voiceSettingsPane',
            ),
          ),
        ),
      ],
      child: widget.child,
    );
  }

  List<ControlOptionEntry> _deviceOptions({
    required bool supported,
    required String? selectedId,
    required Future<void> Function(AudioDevice?) onPick,
  }) {
    if (!supported) return const [];
    final resolved = resolveAudioDevice(_inputs, selectedId);
    return [
      const ControlOptionHeading('Microphone'),
      ControlOption(
        label: 'System default',
        selected: resolved == null,
        onSelected: () => unawaited(onPick(null)),
      ),
      for (final device in _inputs)
        ControlOption(
          label: device.label.isEmpty ? 'Unnamed device' : device.label,
          selected: device.id == resolved?.id,
          onSelected: () => unawaited(onPick(device)),
        ),
    ];
  }
}
