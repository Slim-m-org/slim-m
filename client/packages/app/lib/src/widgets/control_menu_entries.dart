// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The entries a call control's options menu holds beyond a plain row, so the
/// microphone, camera and share menus are built from the same four parts: a
/// device row that opens its list, one-of choices, switches and actions.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

import 'control_options_menu.dart';
import 'control_swatch_row.dart' show ControlOptionEntry;

/// A row showing [value] that opens a list of [options] beside it on a wide window and in place of the sheet on a compact one.
///
/// [panel] replaces the plain [options] for a list that loads, such as screen sources.
class ControlSubmenu extends ControlOptionEntry {
  const ControlSubmenu({
    required this.label,
    required this.icon,
    this.value,
    this.options = const [],
    this.panel,
  });

  final String label;
  final IconData icon;

  /// The current choice, shown at the row's end.
  final String? value;
  final List<ControlOption> options;
  final Widget Function(BuildContext context, VoidCallback close)? panel;
}

/// A one-of choice drawn as a segmented control under a small [label].
class ControlSegmented extends ControlOptionEntry {
  const ControlSegmented({
    required this.label,
    required this.options,
    required this.selectedIndex,
    required this.onSelected,
    this.note,
  });

  final String label;
  final String? note;
  final List<AppSegmentedOption> options;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
}

/// An on/off setting; a menu never marks one with a checkmark.
class ControlSwitch extends ControlOptionEntry {
  const ControlSwitch({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
}

/// A live widget under a row, such as the input level meter, inset to the menu's content edges.
class ControlInline extends ControlOptionEntry {
  const ControlInline(this.builder);

  final WidgetBuilder builder;
}

/// [groups] in one list with a divider between each pair of non-empty ones.
List<ControlOptionEntry> joinMenuGroups(List<List<ControlOptionEntry>> groups) {
  final shown = [
    for (final group in groups)
      if (group.isNotEmpty) group,
  ];
  return [
    for (var i = 0; i < shown.length; i++) ...[
      if (i > 0) const ControlOptionDivider(),
      ...shown[i],
    ],
  ];
}
