// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this build can actually open a microphone or capture a screen on
/// this device, checked on request rather than assumed.
///
/// Nothing runs on screen entry: probing hardware can be slow and can raise a
/// permission prompt, so the button is the affordance, not silent background
/// work. A probe that cannot finish renders as "could not tell", never as
/// every capability failing: claiming a capability is missing when the probe
/// merely errored would be a worse answer than none.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../diagnostics/debug_log.dart';
import '../../../providers/providers.dart';
import '../../settings/widgets/settings_detail_row.dart';
import '../../settings/widgets/settings_section_header.dart';

enum _CheckStatus { idle, running, done, unknown }

class MediaCapabilitySection extends ConsumerStatefulWidget {
  const MediaCapabilitySection({super.key, this.extraRows = const []});

  /// Rows that share this card, below the check.
  final List<Widget> extraRows;

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
    return SettingsSectionCard(
      title: 'This device',
      children: [
        AppListRow(
          leading: const SettingsIconTile(AppIcons.deviceCheck),
          label: 'Device check',
          subtitle: 'Tests your microphone, camera and screen capture.',
          trailing: AppButton(
            size: AppButtonSize.sm,
            label: _buttonLabel(),
            onPressed: _status == _CheckStatus.running ? null : _run,
          ),
        ),
        if (_status == _CheckStatus.unknown)
          SettingsCardBlock(
            children: [
              AppErrorState(
                message: 'Could not tell what this device supports.',
                detail: '$_failure',
              ),
            ],
          ),
        if (_status == _CheckStatus.done) ...[
          _CapabilityRow(label: 'Microphone', result: _results['microphone']!),
          _CapabilityRow(label: 'Camera', result: _results['camera']!),
          _CapabilityRow(
            label: 'Screen capture',
            result: _results['screen_capture']!,
          ),
        ],
        ...widget.extraRows,
      ],
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
    final icon = result.supported ? AppIcons.check : AppIcons.dismiss;
    final color = result.supported ? tokens.status.online : tokens.dangerText;
    final detail = result.supported
        ? 'Works on this device.'
        : 'Not working: ${result.error}';

    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.fromLTRB(62, 6, AppSpacing.s16, 6),
      color: Color.lerp(tokens.surfaceBase, tokens.surfaceRaised, 0.5),
      child: Row(
        spacing: AppSpacing.s12,
        children: [
          Icon(icon, size: AppSizes.icon16, color: color),
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: AppText.caption.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.medium,
              ),
            ),
          ),
          Expanded(
            child: Text(
              detail,
              style: AppText.caption.copyWith(
                color: result.supported
                    ? tokens.textSecondary
                    : tokens.dangerText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
