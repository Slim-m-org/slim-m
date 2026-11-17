// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "Category" row of the channel sheets: the current place, and a picker
/// over every category and "No category".
library;

import 'package:flutter/material.dart';
import 'package:slimm_data/data.dart';

import '../../settings/widgets/settings_select_row.dart';
import 'category_tree.dart';

/// The picker's value for "no category"; a category id is never empty.
const noCategory = '';

class CategoryChoiceRow extends StatelessWidget {
  const CategoryChoiceRow({
    super.key,
    required this.categories,
    required this.value,
    required this.onChanged,
    this.label = 'Category',
  });

  final List<ChannelCategoryRow> categories;

  /// A category id, or [noCategory].
  final String value;
  final ValueChanged<String> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final paths = categoryPaths(categories);
    return SettingsSelectRow<String>(
      label: label,
      value: value,
      choices: [
        const SettingsChoice(value: noCategory, label: 'No category'),
        for (final entry in paths.entries)
          SettingsChoice(value: entry.key, label: entry.value),
      ],
      onChanged: onChanged,
    );
  }
}
