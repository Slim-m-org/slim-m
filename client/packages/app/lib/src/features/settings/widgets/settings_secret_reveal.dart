// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The card that shows a secret exactly once (a bot token, a webhook URL).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'settings_section_header.dart';

/// [value] stays on screen until [onDismiss]; the server keeps only a hash.
class SettingsSecretReveal extends StatefulWidget {
  const SettingsSecretReveal({
    super.key,
    required this.warning,
    required this.value,
    required this.valueSemanticsLabel,
    required this.copyLabel,
    required this.onDismiss,
    this.extraCopyLabel,
    this.extraCopyValue,
  });

  final String warning;
  final String value;
  final String valueSemanticsLabel;
  final String copyLabel;
  final VoidCallback onDismiss;

  /// A second copy action for the same secret in another shape, never drawn.
  final String? extraCopyLabel;
  final String? extraCopyValue;

  @override
  State<SettingsSecretReveal> createState() => _SettingsSecretRevealState();
}

class _SettingsSecretRevealState extends State<SettingsSecretReveal> {
  static const _confirmationHold = Duration(seconds: 2);
  String? _copiedLabel;
  bool _copyFailed = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy(String label, String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } on Object catch (error, stack) {
      api.reportFailure(api.LogTag.ui, 'copy a one-time secret', error, stack);
      if (mounted) setState(() => _copyFailed = true);
      return;
    }
    if (!mounted) return;
    setState(() {
      _copiedLabel = label;
      _copyFailed = false;
    });
    _reset?.cancel();
    _reset = Timer(_confirmationHold, () {
      if (mounted) setState(() => _copiedLabel = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsSectionCard(
      children: [
        SettingsCardBlock(
          gap: AppSpacing.s12,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AppSpacing.s8,
              children: [
                Icon(AppIcons.warning, size: 18, color: tokens.warnText),
                Expanded(
                  child: Text(
                    widget.warning,
                    style: AppText.caption.copyWith(color: tokens.textPrimary),
                  ),
                ),
              ],
            ),
            SelectableText(
              widget.value,
              style: AppText.code,
              semanticsLabel: widget.valueSemanticsLabel,
            ),
            Wrap(
              spacing: AppSpacing.s8,
              runSpacing: AppSpacing.s8,
              children: [
                AppButton(
                  label: _copiedLabel == widget.copyLabel
                      ? 'Copied'
                      : widget.copyLabel,
                  variant: AppButtonVariant.primary,
                  size: AppButtonSize.sm,
                  icon: AppIcons.copy,
                  onPressed: () => _copy(widget.copyLabel, widget.value),
                ),
                if (widget.extraCopyLabel case final label?)
                  AppButton(
                    label: _copiedLabel == label ? 'Copied' : label,
                    variant: AppButtonVariant.secondary,
                    size: AppButtonSize.sm,
                    icon: AppIcons.copy,
                    onPressed: () =>
                        _copy(label, widget.extraCopyValue ?? widget.value),
                  ),
                AppButton(
                  label: 'Done',
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.sm,
                  onPressed: widget.onDismiss,
                ),
              ],
            ),
            if (_copyFailed)
              const AppErrorState(
                message:
                    'Could not copy. Select the text above and copy it by hand.',
              ),
          ],
        ),
      ],
    );
  }
}
