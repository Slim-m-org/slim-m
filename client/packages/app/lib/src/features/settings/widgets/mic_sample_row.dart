// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Troubleshooting row that records 30 seconds of the raw microphone, for
/// the noise corpus. It saves a WAV on this device and uploads nothing.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../voice/providers/mic_preview.dart';
import '../providers/mic_sample_controller.dart';
import 'settings_detail_row.dart';
import 'settings_result_inset.dart';

class MicSampleRow extends ConsumerStatefulWidget {
  const MicSampleRow({super.key});

  @override
  ConsumerState<MicSampleRow> createState() => _MicSampleRowState();
}

class _MicSampleRowState extends ConsumerState<MicSampleRow> {
  late final MicSampleController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(micSampleControllerProvider.notifier);
  }

  @override
  void dispose() {
    _controller.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(micSampleSupportedProvider)) return const SizedBox.shrink();
    final sample = ref.watch(micSampleControllerProvider);
    final controller = _controller;
    final inCall = ref.watch(micPreviewBlockedProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsDetailRow(
          icon: AppIcons.mic,
          title: 'Record a mic sample',
          detail: _detail(sample, inCall),
          error: sample.error,
          onErrorDismiss: controller.dismiss,
          trailing: AppButton(
            size: AppButtonSize.sm,
            label: sample.recording ? 'Stop' : 'Record',
            onPressed: sample.recording
                ? controller.stop
                : inCall
                ? null
                : () => unawaited(controller.start()),
          ),
        ),
        if (sample.recording) _Countdown(sample),
      ],
    );
  }

  String _detail(MicSampleState sample, bool inCall) {
    if (sample.recording) return 'Talk, then chew, swallow and type.';
    if (sample.fileName != null) return 'Saved as ${sample.fileName}.';
    if (inCall) return 'Leave the call to record.';
    return '30 seconds of the raw mic, kept on this device.';
  }
}

class _Countdown extends StatelessWidget {
  const _Countdown(this.sample);

  final MicSampleState sample;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsResultInset(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AppSpacing.s4,
        children: [
          Text(
            '${sample.secondsLeft} s left',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          LinearProgressIndicator(
            value: sample.secondsKept / sample.total,
            minHeight: 3,
            semanticsLabel: 'Mic sample',
          ),
        ],
      ),
    );
  }
}
