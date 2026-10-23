// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One caught event in the debug log: a single line of time, level marker,
/// area and message that opens in place to the full text and any detail.
///
/// Severity never rides on colour alone: a distinct glyph silhouette (octagon,
/// triangle, circle) and the spoken level word carry it, the tint only
/// reinforces. Copy appears on hover and on long-press, and the open entry
/// has a visible Copy button for touch.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../diagnostics/debug_log.dart';
import '../../../providers/toasts.dart';

const double _timeWidth = 56;
const double _areaWidth = 60;

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
    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
    final reduced = AppMotion.isReduced(context);
    final message = entry.count > 1
        ? '${entry.message} (x${entry.count})'
        : entry.message;

    return GestureDetector(
      onLongPress: _copy,
      child: FocusableTapTarget(
        semanticLabel:
            '$_levelWord, ${entry.source}, ${entry.timestamp}: '
            '$message',
        selected: _open,
        onTap: () => setState(() => _open = !_open),
        builder: (context, focused, hovered) => AnimatedContainer(
          duration: reduced ? Duration.zero : AppMotion.fast,
          width: double.infinity,
          color: _open
              ? Color.lerp(tokens.surfaceBase, tokens.surfaceRaised, 0.5)
              : hovered
              ? tokens.surfaceSunken
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s12,
            vertical: AppSpacing.s4,
          ),
          child: _sized(
            reduced,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExcludeSemantics(
                  child: _line(tokens, message, hovered, compact),
                ),
                if (_open) _expanded(tokens),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sized(bool reduced, Widget child) => reduced
      ? child
      : AnimatedSize(
          duration: AppMotion.fast,
          alignment: Alignment.topCenter,
          child: child,
        );

  int? _messageMaxLines(bool compact) {
    if (_open) return null;
    return compact ? 2 : 1;
  }

  Widget _line(AppTokens tokens, String message, bool hovered, bool compact) {
    final entry = widget.entry;
    final mono = AppText.micro.copyWith(
      color: tokens.textSecondary,
      fontFamily: AppFonts.mono,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      spacing: AppSpacing.s8,
      children: [
        SizedBox(
          width: _timeWidth,
          child: Text(entry.timestamp, style: mono),
        ),
        Icon(_levelIcon, size: AppSizes.icon16, color: _levelColor(tokens)),
        SizedBox(
          width: _areaWidth,
          child: Text(
            entry.source,
            overflow: TextOverflow.ellipsis,
            style: mono,
          ),
        ),
        Expanded(
          child: Text(
            message,
            maxLines: _messageMaxLines(compact),
            overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: tokens.textPrimary),
          ),
        ),
        if (hovered && !_open && !compact)
          AppIconButton(
            icon: AppIcons.copy,
            semanticLabel: 'Copy this entry',
            tooltip: 'Copy this entry',
            size: AppIconButtonSize.sm,
            iconSize: AppSizes.icon16,
            onPressed: _copy,
          ),
        Icon(
          _open ? AppIcons.chevronUp : AppIcons.chevronDown,
          size: AppSizes.icon16,
          color: tokens.textSecondary,
        ),
      ],
    );
  }

  Widget _expanded(AppTokens tokens) {
    final detail = widget.entry.expandedText;
    return Padding(
      padding: const EdgeInsets.only(
        left: _timeWidth + AppSpacing.s8,
        top: AppSpacing.s4,
        bottom: AppSpacing.s8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.s8,
        children: [
          if (detail != null) _DetailBlock(detail),
          AppButton(
            label: 'Copy entry',
            icon: AppIcons.copy,
            size: AppButtonSize.sm,
            variant: AppButtonVariant.ghost,
            onPressed: _copy,
          ),
        ],
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
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s12,
        vertical: AppSpacing.s8,
      ),
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
