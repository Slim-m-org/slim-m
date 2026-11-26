// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One optional call control: the button it draws in the dock, and the rows it
/// offers inside the dock's More menu.
library;

import 'package:flutter/widgets.dart';

import '../../../widgets/control_swatch_row.dart' show ControlOptionEntry;

class DockItem {
  const DockItem({
    required this.id,
    required this.name,
    required this.inline,
    required this.entries,
    this.keepInline = false,
  });

  /// What this device remembers when the person pins the item out of More.
  final String id;

  /// Names the item in the pin list, where its menu rows are not shown.
  final String name;

  /// The control as it stands in the dock row.
  final Widget inline;

  /// The rows More shows for it.
  final List<ControlOptionEntry> entries;

  /// Stays in the dock whatever the person pinned, such as captions that are on.
  final bool keepInline;
}
