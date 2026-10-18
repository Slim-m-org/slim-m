// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One caught event in the debug log, with a copy button and, when it has a
/// stack trace, an expander.
///
/// Severity never rides on colour alone: a distinct glyph silhouette (octagon,
/// triangle, circle) and the spoken level word carry it, the tint only
/// reinforces.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../diagnostics/debug_log.dart';
import '../../../providers/toasts.dart';

class DebugLogEntry extends ConsumerStatefulWidget {
  const DebugLogEntry({super.key, required this.entry});

  final DiagnosticEvent entry;

  @override
  ConsumerState<DebugLogEntry> createState() => _DebugLogEntryState();
}

class _DebugLogEntryState extends ConsumerState<DebugLogEntry> {
  bool _open = false;

  Color _levelColor(AppTokens tokens) => switch (widget.entry.level) {
    DiagnosticSeverity.error => tokens.dangerText,
    DiagnosticSeverity.warning => tokens.warnText,
    DiagnosticSeverity.info || DiagnosticSeverity.debug => tokens.textSecondary,
  };

  IconData get _levelIcon => switch (widget.entry.level) {
    DiagnosticSeverity.error => AppIcons.danger,
    DiagnosticSeverity.warning => AppIcons.warning,
    DiagnosticSeverity.info || DiagnosticSeverity.debug => AppIcons.info,
  };

  String get _levelWord => switch (widget.entry.level) {
    DiagnosticSeverity.error => 'Error',
    DiagnosticSeverity.warning => 'Warning',
    DiagnosticSeverity.info => 'Info',
    DiagnosticSeverity.debug => 'Debug',
  };

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.entry.toString()));
    if (!mounted) return;
    ref
        .read(toastsProvider.notifier)
        .show('Entry copied', severity: AppToastSeverity.success);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final entry = widget.entry;
    final level = _levelColor(tokens);
    final detail = entry.expandedText;

    final reduced = AppMotion.isReduced(context);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          spacing: AppSpacing.s8,
          children: [
            Text(
              _levelWord,
              style: AppText.micro.copyWith(
                color: level,
                fontWeight: AppWeights.semi,
              ),
            ),
            _SourceChip(entry.source),
            Expanded(
              child: Text(
                entry.timestamp,
                textAlign: TextAlign.end,
                style: AppText.micro.copyWith(
                  color: tokens.textSecondary,
                  fontFamily: AppFonts.mono,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s4),
        Text(
          entry.count > 1
              ? '${entry.message} (x${entry.count})'
              : entry.message,
          style: AppText.caption.copyWith(color: tokens.textPrimary),
        ),
        if (_open && detail != null) _DetailBlock(detail),
      ],
    );

    return AnimatedContainer(
      duration: reduced ? Duration.zero : AppMotion.fast,
      color: _open
          ? Color.lerp(tokens.surfaceBase, tokens.surfaceRaised, 0.5)
          : Colors.transparent,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        AppSpacing.s12,
        AppSpacing.s8,
        AppSpacing.s12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.s12,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(_levelIcon, size: AppSizes.icon16, color: level),
          ),
          Expanded(
            child: reduced
                ? body
                : AnimatedSize(
                    duration: AppMotion.fast,
                    alignment: Alignment.topCenter,
                    child: body,
                  ),
          ),
          AppIconButton(
            icon: AppIcons.copy,
            semanticLabel: 'Copy this entry',
            tooltip: 'Copy this entry',
            size: AppIconButtonSize.sm,
            iconSize: AppSizes.icon16,
            onPressed: _copy,
          ),
          if (detail != null)
            AppIconButton(
              icon: _open ? AppIcons.chevronUp : AppIcons.chevronDown,
              semanticLabel: _open ? 'Hide detail' : 'Show detail',
              tooltip: _open ? 'Hide detail' : 'Show detail',
              size: AppIconButtonSize.sm,
              iconSize: AppSizes.icon16,
              onPressed: () => setState(() => _open = !_open),
            )
          else
            const SizedBox(width: AppSizes.controlSm),
        ],
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip(this.source);

  final String source;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        source,
        overflow: TextOverflow.ellipsis,
        style: AppText.micro.copyWith(
          color: tokens.textSecondary,
          fontFamily: AppFonts.mono,
        ),
      ),
    );
  }
}

class _DetailBlock extends StatelessWidget {
  const _DetailBlock(this.detail);

  final String detail;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: SelectableText(
        detail,
        style: AppText.code.copyWith(
          fontSize: AppText.caption.fontSize,
          color: tokens.textSecondary,
        ),
      ),
    );
  }
}
