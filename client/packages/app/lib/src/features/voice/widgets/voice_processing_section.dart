// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Echo, gain and noise filters one by one, folded away in the microphone
/// card on a host with the native capture chain.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceProcessing;

import '../providers/voice_processing.dart';
import '../../settings/widgets/settings_disclosure.dart';
import '../../settings/widgets/settings_toggle_row.dart';

class VoiceProcessingSection extends ConsumerWidget {
  const VoiceProcessingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final processing = ref.watch(voiceProcessingProvider);
    final notifier = ref.read(voiceProcessingProvider.notifier);
    return SettingsDisclosure(
      title: 'Advanced',
      summary: _summary(processing),
      children: [
        SettingsToggleRow(
          label: 'Echo cancellation',
          description: 'Keeps your speakers out of your mic.',
          value: processing.echoCancellation,
          semanticLabel: 'Echo cancellation',
          onChanged: (v) =>
              notifier.set(processing.copyWith(echoCancellation: v)),
        ),
        SettingsToggleRow(
          label: 'Automatic gain',
          description: 'Lifts a quiet mic.',
          value: processing.autoGainControl,
          semanticLabel: 'Automatic gain',
          onChanged: (v) =>
              notifier.set(processing.copyWith(autoGainControl: v)),
        ),
        SettingsToggleRow(
          label: 'Built-in noise suppression',
          description: 'Removes steady background noise.',
          value: processing.noiseSuppression,
          semanticLabel: 'Built-in noise suppression',
          onChanged: (v) =>
              notifier.set(processing.copyWith(noiseSuppression: v)),
        ),
      ],
    );
  }

  static String _summary(VoiceProcessing p) {
    final off = [
      p.echoCancellation,
      p.autoGainControl,
      p.noiseSuppression,
    ].where((on) => !on).length;
    return off == 0 ? 'All on' : '$off off';
  }
}
