// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock's microphone options: input and speaker device, noise
/// suppression and the input toggles, all backed by the providers Voice
/// settings already uses.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart' show AudioDevice;

import '../../../routing/routes.dart';
import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart' show ControlOptionEntry;
import '../providers/noise_suppression.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_settings_controller.dart';
import 'call_device_options.dart';

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
  final _expanded = <String>{};

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

  VoidCallback _toggle(String group) =>
      () => setState(() {
        if (!_expanded.remove(group)) _expanded.add(group);
      });

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
    final spaceStrong = controller.input.spaceStrongNoiseSuppression.value;
    final notifier = ref.read(voiceSettingsControllerProvider.notifier);
    return ControlOptionsMenu(
      optionsLabel: 'Microphone options',
      showCaret: widget.showCaret,
      destructive: widget.destructive,
      menuWidth: deviceMenuWidth,
      options: [
        if (controller.devices.supportsAudioInputSelection)
          ...audioDeviceOptions(
            heading: 'Microphone',
            devices: _inputs,
            selectedId: settings.audioInputDeviceId,
            onPick: notifier.setAudioInputDevice,
            expanded: _expanded.contains('Microphone'),
            onToggle: _toggle('Microphone'),
          ),
        if (controller.devices.supportsAudioOutputSelection)
          ...audioDeviceOptions(
            heading: 'Speaker',
            devices: _outputs,
            selectedId: settings.audioOutputDeviceId,
            onPick: notifier.setAudioOutputDevice,
            expanded: _expanded.contains('Speaker'),
            onToggle: _toggle('Speaker'),
          ),
        if (controller.input.supportsInputGate) ...[
          ...collapsibleOptions(
            heading: _noiseSuppression,
            expanded: _expanded.contains(_noiseSuppression),
            onToggle: _toggle(_noiseSuppression),
            options: [
              for (final choice in NoiseSuppressionChoice.offered(
                supported: ref.watch(strongestSupportedProvider),
              ))
                ControlOption(
                  label: noiseSuppressionLabel(
                    choice,
                    spaceStrong: spaceStrong,
                  ),
                  selected: choice == noise,
                  onSelected: () => unawaited(
                    ref.read(noiseSuppressionProvider.notifier).set(choice),
                  ),
                ),
            ],
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
}
