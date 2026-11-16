// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The theme editor's one place to save, pinned under the colours at every
/// width: Save, Save and apply, and while they are off, why, with Fix all.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class ThemeEditorFooter extends StatelessWidget {
  const ThemeEditorFooter({
    super.key,
    required this.failingChecks,
    required this.nameValid,
    required this.busy,
    required this.compact,
    required this.inset,
    required this.onSave,
    required this.onSaveAndApply,
    required this.onFixAll,
    required this.onShowContrast,
  });

  final int failingChecks;
  final bool nameValid;
  final bool busy;

  /// A narrow editor: the reason over a touch-height row of both buttons.
  final bool compact;

  /// The page's side inset, so the buttons end where the cards do.
  final double inset;
  final VoidCallback onSave;
  final VoidCallback onSaveAndApply;
  final VoidCallback onFixAll;

  /// Brings the Contrast card into view.
  final VoidCallback onShowContrast;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final blocked = failingChecks > 0 || !nameValid;
    final why = failingChecks > 0
        ? _Why(
            title:
                '$failingChecks ${failingChecks == 1 ? 'check fails' : 'checks fail'}.',
            detail: 'Fix them under Contrast to save.',
            onTap: onShowContrast,
            action: AppButton(
              key: const Key('theme-editor-fix-all'),
              label: 'Fix all',
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.sm,
              onPressed: onFixAll,
            ),
          )
        : !nameValid
        ? const _Why(
            title: 'Give it a name of 1 to $themeNameMaxChars characters.',
          )
        : null;
    final save = AppButton(
      key: const Key('theme-editor-save'),
      label: 'Save',
      variant: AppButtonVariant.secondary,
      full: compact,
      touch: compact ? true : null,
      disabled: busy || blocked,
      onPressed: onSave,
    );
    final apply = AppButton(
      key: const Key('theme-editor-apply'),
      label: 'Save and apply',
      variant: AppButtonVariant.primary,
      full: compact,
      touch: compact ? true : null,
      disabled: busy || blocked,
      onPressed: onSaveAndApply,
    );
    return DecoratedBox(
      key: const Key('theme-editor-footer'),
      decoration: BoxDecoration(
        color: tokens.surfaceBase,
        border: Border(top: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          inset,
          AppSpacing.s12,
          inset,
          (compact ? AppSpacing.s16 : AppSpacing.s12) +
              MediaQuery.paddingOf(context).bottom,
        ),
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                spacing: AppSpacing.s12,
                children: [
                  ?why,
                  Row(
                    spacing: AppSpacing.s8,
                    children: [
                      Expanded(child: save),
                      Expanded(child: apply),
                    ],
                  ),
                ],
              )
            : Row(
                spacing: AppSpacing.s8,
                children: [
                  Expanded(child: why ?? const SizedBox.shrink()),
                  save,
                  apply,
                ],
              ),
      ),
    );
  }
}

/// Why the buttons are off, and the shortest way to turn them on.
class _Why extends StatelessWidget {
  const _Why({required this.title, this.detail, this.onTap, this.action});

  final String title;
  final String? detail;
  final VoidCallback? onTap;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final text = Row(
      spacing: AppSpacing.s8,
      children: [
        Icon(AppIcons.warning, size: AppSizes.icon16, color: tokens.warnText),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: AppText.ui.copyWith(color: tokens.textPrimary),
              ),
              if (detail case final detail?)
                Text(
                  detail,
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
            ],
          ),
        ),
      ],
    );
    return Row(
      key: const Key('theme-editor-why'),
      spacing: AppSpacing.s8,
      children: [
        Expanded(
          child: onTap == null
              ? text
              : _Link(
                  label: [title, ?detail].join(' '),
                  onTap: onTap!,
                  child: text,
                ),
        ),
        ?action,
      ],
    );
  }
}

/// A tap on the reason; its focus ring sits inside its edge so the icon keeps its place.
class _Link extends StatelessWidget {
  const _Link({required this.label, required this.onTap, required this.child});

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadii.control);
    return Semantics(
      key: const Key('theme-editor-why-link'),
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: AppInsetFocus(
        builder: (context, onFocusChange, focused) => InkWell(
          borderRadius: radius,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          onFocusChange: onFocusChange,
          onTap: onTap,
          child: Container(
            foregroundDecoration: appInsetFocusDecoration(
              context,
              focused: focused,
              borderRadius: radius,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
