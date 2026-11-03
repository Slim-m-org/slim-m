// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pickers a [SettingsSelectRow] opens once it has too many choices to
/// read as a plain list: a height-bounded, scrolling list with a search field.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_select_row.dart';

/// More choices than this get a search field and a bounded scrolling list.
const int kSearchableChoiceThreshold = 8;

const double _listMaxHeight = 280;
const double _dropdownWidth = 300;

bool choicesNeedSearch(int count) => count > kSearchableChoiceThreshold;

/// A phone's bottom sheet of [choices], searchable and capped in height.
Future<T?> showSearchableChoiceSheet<T>(
  BuildContext context, {
  required String title,
  required T? value,
  required List<SettingsChoice<T>> choices,
}) {
  return showAppSheet<T>(
    context,
    bare: true,
    scrolls: true,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: AppSheetMenu(
        children: [
          AppMenuLabel(title),
          SearchableChoiceList<T>(
            choices: choices,
            value: value,
            onPick: (v) => Navigator.of(sheetContext).pop(v),
          ),
        ],
      ),
    ),
  );
}

/// A desktop dropdown of [choices] anchored at [position], searchable and capped in height.
Future<T?> showSearchableChoiceMenu<T>(
  BuildContext context, {
  required RelativeRect position,
  required T? value,
  required List<SettingsChoice<T>> choices,
}) {
  final tokens = Theme.of(context).extension<AppTokens>()!;
  return showMenu<T>(
    context: context,
    position: position,
    color: tokens.surfaceRaised,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.card),
      side: BorderSide(color: tokens.borderStrong),
    ),
    constraints: const BoxConstraints(
      minWidth: _dropdownWidth,
      maxWidth: _dropdownWidth,
    ),
    items: [_SearchableEntry<T>(value: value, choices: choices)],
  );
}

/// The search field and the scrolling list under it.
class SearchableChoiceList<T> extends StatefulWidget {
  const SearchableChoiceList({
    super.key,
    required this.choices,
    required this.value,
    required this.onPick,
  });

  final List<SettingsChoice<T>> choices;
  final T? value;
  final ValueChanged<T> onPick;

  @override
  State<SearchableChoiceList<T>> createState() =>
      _SearchableChoiceListState<T>();
}

class _SearchableChoiceListState<T> extends State<SearchableChoiceList<T>> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<SettingsChoice<T>> get _matches {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return widget.choices;
    return [
      for (final c in widget.choices)
        if (c.label.toLowerCase().contains(q)) c,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final matches = _matches;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s4,
            AppSpacing.s4,
            AppSpacing.s4,
            AppSpacing.s8,
          ),
          child: AppInput(
            key: const ValueKey('choice-search'),
            controller: _query,
            icon: const Icon(AppIcons.search, size: AppSizes.icon16),
            placeholder: 'Search',
            autofocus: true,
            semanticLabel: 'Search choices',
            onChanged: (_) => setState(() {}),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _listMaxHeight),
          child: matches.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AppSpacing.s12),
                  child: Text(
                    'No matches',
                    style: AppText.body.copyWith(color: tokens.textSecondary),
                  ),
                )
              : ListView(
                  key: const ValueKey('choice-list'),
                  shrinkWrap: true,
                  children: [
                    for (final c in matches)
                      AppMenuItem(
                        label: c.label,
                        leadingWidget: c.leading,
                        selected: c.value == widget.value,
                        onTap: () => widget.onPick(c.value),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _SearchableEntry<T> extends PopupMenuEntry<T> {
  const _SearchableEntry({required this.value, required this.choices});

  final T? value;
  final List<SettingsChoice<T>> choices;

  @override
  double get height => _listMaxHeight + AppSizes.controlMd + AppSpacing.s16;

  @override
  bool represents(T? value) => false;

  @override
  State<_SearchableEntry<T>> createState() => _SearchableEntryState<T>();
}

class _SearchableEntryState<T> extends State<_SearchableEntry<T>> {
  @override
  Widget build(BuildContext context) => SearchableChoiceList<T>(
    choices: widget.choices,
    value: widget.value,
    onPick: (v) => Navigator.of(context).pop(v),
  );
}
