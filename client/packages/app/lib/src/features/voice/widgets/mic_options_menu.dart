// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock's microphone options: input and speaker device, the input
/// level, noise suppression and the input switches, all backed by the providers Voice
/// settings already uses.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart' show AudioDevice;

import '../../../routing/routes.dart';
import '../../../widgets/control_menu_entries.dart';
import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart' show ControlOptionEntry;
import '../providers/noise_suppression.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_settings_controller.dart';
import 'call_device_options.dart';
import 'input_sensitivity_section.dart' show InputSensitivityMeter;

/// The voice settings pane the menu's last row opens.
const voiceSettingsPane = 'voice';

const _noiseSuppression = 'Noise suppression';

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
  List<AudioDevice> _outputs = const [];
  StreamSubscription<void>? _changes;
  late final ValueNotifier<bool> _spaceStrong;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _changes = ref
        .read(voiceControllerProvider.notifier)
        .devices
        .audioDeviceChanges
        .listen((_) => unawaited(_refresh()));
    _spaceStrong =
        ref
            .read(voiceControllerProvider.notifier)
            .input
            .spaceStrongNoiseSuppression
          ..addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    _spaceStrong.removeListener(_rebuild);
    super.dispose();
  }

  Future<void> _refresh() async {
    final devices = ref.read(voiceControllerProvider.notifier).devices;
    final inputs = await devices.audioInputDevices();
    final outputs = devices.supportsAudioOutputSelection
        ? await devices.audioOutputDevices()
        : const <AudioDevice>[];
    if (!mounted) return;
    setState(() {
      _inputs = inputs;
      _outputs = outputs;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(voiceSettingsControllerProvider);
    final noise = ref.watch(noiseSuppressionProvider);
    final controller = ref.read(voiceControllerProvider.notifier);
    final gated = controller.input.supportsInputGate;
    final spaceStrong = controller.input.spaceStrongNoiseSuppression.value;
    final notifier = ref.read(voiceSettingsControllerProvider.notifier);
    return ControlOptionsMenu(
      optionsLabel: 'Microphone options',
      showCaret: widget.showCaret,
      destructive: widget.destructive,
      menuWidth: callMenuWidth,
      options: joinMenuGroups([
        [
          if (controller.devices.supportsAudioInputSelection)
            ControlSubmenu(
              label: 'Microphone',
              icon: AppIcons.mic,
              value: audioDeviceValue(_inputs, settings.audioInputDeviceId),
              options: audioDeviceOptions(
                devices: _inputs,
                selectedId: settings.audioInputDeviceId,
                onPick: notifier.setAudioInputDevice,
              ),
            ),
          if (gated) const ControlInline(_inputMeter),
          if (controller.devices.supportsAudioOutputSelection)
            ControlSubmenu(
              label: 'Speaker',
              icon: AppIcons.speaker,
              value: audioDeviceValue(_outputs, settings.audioOutputDeviceId),
              options: audioDeviceOptions(
                devices: _outputs,
                selectedId: settings.audioOutputDeviceId,
                onPick: notifier.setAudioOutputDevice,
              ),
            ),
        ],
        if (gated) [_noiseChoice(noise, spaceStrong)],
        [
          if (gated) ...[
            ControlSwitch(
              label: 'Automatic sensitivity',
              value: settings.inputThresholdAuto,
              onChanged: (value) =>
                  unawaited(notifier.setInputThresholdAuto(value)),
            ),
            ControlSwitch(
              label: 'Even out loud sounds',
              value: settings.evenOutLoudSounds,
              onChanged: (value) =>
                  unawaited(notifier.setEvenOutLoudSounds(value)),
            ),
          ],
        ],
        [
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
      ]),
      child: widget.child,
    );
  }

  ControlSegmented _noiseChoice(
    NoiseSuppressionChoice noise,
    bool spaceStrong,
  ) {
    final choices = NoiseSuppressionChoice.offered(
      supported: ref.watch(strongestSupportedProvider),
    );
    final shown = choices.contains(noise)
        ? noise
        : NoiseSuppressionChoice.strong;
    return ControlSegmented(
      label: _noiseSuppression,
      note: 'Default: ${spaceStrong ? 'Strong' : 'Standard'}',
      options: [
        for (final choice in choices)
          AppSegmentedOption(label: noiseSegmentLabel(choice)),
      ],
      selectedIndex: choices.indexOf(shown),
      onSelected: (i) => unawaited(
        ref.read(noiseSuppressionProvider.notifier).set(choices[i]),
      ),
    );
  }
}

Widget _inputMeter(BuildContext context) =>
    const InputSensitivityMeter(compact: true);
