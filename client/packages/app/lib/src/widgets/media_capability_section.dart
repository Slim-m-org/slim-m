// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this build can actually open a microphone or capture a screen on
/// this device, checked on request rather than assumed.
///
/// Nothing runs on screen entry: probing hardware can be slow and can raise a
/// permission prompt, so the button is the affordance, not silent background
/// work. A probe that cannot finish (an exception from the batch call, never
/// expected given [MediaCapabilities.probeAll]'s own contract but guarded
/// against anyway) renders as "could not tell", never as every capability
/// failing: claiming a capability is missing when the probe merely errored
/// would be a worse answer than none.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../diagnostics/debug_log.dart';
import '../providers/providers.dart';
import 'settings_section_header.dart';

enum _CheckStatus { idle, running, done, unknown }

class MediaCapabilitySection extends ConsumerStatefulWidget {
  const MediaCapabilitySection({super.key, this.embedded = false});

  /// Rows only, for a card another section already owns.
  final bool embedded;

  @override
  ConsumerState<MediaCapabilitySection> createState() =>
      _MediaCapabilitySectionState();
}

class _MediaCapabilitySectionState
    extends ConsumerState<MediaCapabilitySection> {
  _CheckStatus _status = _CheckStatus.idle;
  Map<String, CapabilityResult> _results = const {};
  Object? _failure;

  Future<void> _run() async {
    setState(() => _status = _CheckStatus.running);
    final log = ref.read(debugLogProvider.notifier);
    try {
      final results = await ref.read(mediaCapabilitiesProvider).probeAll();
      log.record(
        'capabilities',
        'Checked device media capabilities',
        level: DiagnosticSeverity.info,
        detail: results.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
      );
      if (!mounted) return;
      setState(() {
        _status = _CheckStatus.done;
        _results = results;
      });
    } catch (e) {
      log.record(
        'capabilities',
        'Could not check device media capabilities',
        level: DiagnosticSeverity.warning,
        detail: e,
      );
      if (!mounted) return;
      setState(() {
        _status = _CheckStatus.unknown;
        _failure = e;
      });
    }
  }

  String _buttonLabel() => switch (_status) {
    _CheckStatus.running => 'Checking...',
    _CheckStatus.idle => 'Check this device',
    _CheckStatus.done || _CheckStatus.unknown => 'Check again',
  };

  @override
  Widget build(BuildContext context) {
    final rows = [
      AppButton(
        label: _buttonLabel(),
        onPressed: _status == _CheckStatus.running ? null : _run,
      ),
      if (_status == _CheckStatus.unknown) ...[
        const SizedBox(height: AppSpacing.s12),
        AppErrorState(
          message: 'Could not tell what this device supports.',
          detail: '$_failure',
        ),
      ],
      if (_status == _CheckStatus.done) ...[
        const SizedBox(height: AppSpacing.s12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AppSpacing.s12,
          children: [
            _CapabilityRow(
              label: 'Microphone',
              result: _results['microphone']!,
            ),
            _CapabilityRow(label: 'Camera', result: _results['camera']!),
            _CapabilityRow(
              label: 'Screen capture',
              result: _results['screen_capture']!,
            ),
          ],
        ),
      ],
    ];
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      );
    }
    return SettingsSectionCard(
      title: 'Device capabilities',
      description: 'Tests the microphone, camera and screen capture.',
      children: rows,
    );
  }
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({required this.label, required this.result});

  final String label;
  final CapabilityResult result;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final icon = result.supported ? AppIcons.check : AppIcons.danger;
    final color = result.supported ? tokens.textPrimary : tokens.dangerText;
    final detail = result.supported
        ? 'Available: ${result.detail}.'
        : 'Not available: ${result.error}';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppSpacing.s8,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: AppSizes.icon16, color: color),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: AppText.ui.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.medium,
                ),
              ),
              Text(
                detail,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
