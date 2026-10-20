// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A select menu on a bot's message. See
/// docs/decisions/0083-bot-token-reissue-select-menus-and-forms.md.
///
/// Which surface it opens follows docs/design/desktop-vs-mobile.md. Picking
/// one value from a short list for a control that stays on screen is rule 2,
/// the anchored menu (a sheet under 600 wide, via `ContextMenuRegion`). More
/// than eight options, or a choice of several, is a short task with a submit,
/// rule 4: `showAppSheet`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/context_menu_region.dart';

/// The most rows an anchored menu carries; past it the list is a sheet.
const int _menuRows = 8;

const double _fieldMaxWidth = 320;

class MessageSelectView extends StatefulWidget {
  const MessageSelectView({
    super.key,
    required this.select,
    required this.pending,
    required this.disabled,
    required this.onChosen,
  });

  final api.MessageSelect select;
  final bool pending;
  final bool disabled;
  final ValueChanged<List<String>> onChosen;

  @override
  State<MessageSelectView> createState() => _MessageSelectViewState();
}

class _MessageSelectViewState extends State<MessageSelectView> {
  final _menu = GlobalKey<ContextMenuRegionState>();

  bool get _anchored =>
      widget.select.picksOne && widget.select.options.length <= _menuRows;

  void _open() {
    if (_anchored) {
      final box = context.findRenderObject() as RenderBox?;
      final below = box?.localToGlobal(Offset(0, box.size.height));
      _menu.currentState?.open(at: below);
    } else {
      unawaited(_openSheet());
    }
  }

  Future<void> _openSheet() async {
    final chosen = await showAppSheet<List<String>>(
      context,
      scrolls: true,
      builder: (context) => _SelectSheet(select: widget.select),
    );
    if (chosen != null && mounted) widget.onChosen(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final select = widget.select;
    final inert = widget.disabled || widget.pending;
    final field = _SelectField(
      label: select.placeholder ?? 'Choose an option',
      busy: widget.pending,
      onTap: inert ? null : _open,
    );
    if (!_anchored) return field;
    return ContextMenuRegion(
      key: _menu,
      ownsFocusNode: false,
      enableLongPress: false,
      menuWidth: _fieldMaxWidth,
      itemsBuilder: (context, close) => [
        for (final option in select.options)
          AppMenuItem(
            label: option.label,
            onTap: () {
              close();
              widget.onChosen([option.value]);
            },
          ),
      ],
      child: field,
    );
  }
}

class _SelectField extends StatelessWidget {
  const _SelectField({
    required this.label,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final enabled = onTap != null;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _fieldMaxWidth),
      child: FocusableTapTarget(
        semanticLabel: label,
        enabled: enabled,
        onTap: onTap,
        builder: (context, focused, hovered) => Container(
          height: AppSizes.controlMd,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s12),
          decoration: BoxDecoration(
            color: hovered && enabled
                ? tokens.surfaceRaised
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border.all(color: tokens.borderSubtle),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(
                    color: enabled ? tokens.textPrimary : tokens.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              if (busy)
                const AppSpinner(size: AppSpinnerSize.sm)
              else
                Icon(
                  AppIcons.chevronDown,
                  size: AppSizes.icon16,
                  color: tokens.textSecondary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A list to choose from: a tap answers a single pick, a submit answers several.
class _SelectSheet extends StatefulWidget {
  const _SelectSheet({required this.select});

  final api.MessageSelect select;

  @override
  State<_SelectSheet> createState() => _SelectSheetState();
}

class _SelectSheetState extends State<_SelectSheet> {
  final _chosen = <String>{};

  api.MessageSelect get _select => widget.select;

  bool get _ready =>
      _chosen.length >= _select.minValues &&
      _chosen.length <= _select.maxValues;

  void _toggle(String value) {
    if (_select.maxValues == 1) {
      Navigator.of(context).pop([value]);
      return;
    }
    setState(() {
      if (!_chosen.remove(value) && _chosen.length < _select.maxValues) {
        _chosen.add(value);
      }
    });
  }

  String get _hint {
    final min = _select.minValues;
    final max = _select.maxValues;
    if (max == 1) return 'Choose one.';
    if (min == 0) return 'Choose up to $max.';
    return min == max ? 'Choose $max.' : 'Choose $min to $max.';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final multi = _select.maxValues > 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _select.placeholder ?? 'Choose an option',
                  style: AppText.heading.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
              ),
              AppIconButton(
                icon: AppIcons.dismiss,
                semanticLabel: 'Close',
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          if (multi)
            Padding(
              padding: const EdgeInsets.only(
                top: AppSpacing.s4,
                bottom: AppSpacing.s8,
              ),
              child: Text(
                _hint,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final option in _select.options)
                    AppListRow(
                      label: option.label,
                      subtitle: option.description,
                      selected: _chosen.contains(option.value),
                      trailing: _chosen.contains(option.value)
                          ? Icon(
                              AppIcons.check,
                              size: AppSizes.icon16,
                              color: tokens.accent,
                            )
                          : null,
                      onTap: () => _toggle(option.value),
                    ),
                ],
              ),
            ),
          ),
          if (multi) ...[
            const SizedBox(height: AppSpacing.s12),
            AppButton(
              label: 'Choose',
              variant: AppButtonVariant.primary,
              full: true,
              disabled: !_ready,
              onPressed: () =>
                  Navigator.of(context).pop(_chosen.toList(growable: false)),
            ),
          ],
        ],
      ),
    );
  }
}
