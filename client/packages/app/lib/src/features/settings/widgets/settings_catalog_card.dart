// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The card a Space's own uploads are listed in, custom emoji and soundboard
/// clips alike: a title with a count beside it, then the rows.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/sheet_item_list.dart';
import 'settings_section_header.dart';

/// Every row is in one list bounded to part of the window, so a long catalog
/// only builds the rows on screen and the page around it stays put.
class SettingsCatalogCard extends StatelessWidget {
  const SettingsCatalogCard({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    required this.empty,
    this.count,
    this.above = const [],
    this.listKey,
  });

  final String title;

  /// Beside the title, such as "14 of 48"; null shows none.
  final String? count;

  /// Between the title and the rows, such as a search field.
  final List<Widget> above;

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// Shown in place of the rows when [itemCount] is zero.
  final Widget empty;

  /// Marks the list's bounding box, for a test that measures it.
  final Key? listKey;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final count = this.count;
    return SettingsSectionCard(
      title: title,
      trailing: count == null
          ? null
          : Text(
              count,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
      children: [
        ...above,
        if (itemCount == 0)
          empty
        else
          ConstrainedBox(
            key: listKey,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.6,
            ),
            child: SheetItemList(
              padding: EdgeInsets.zero,
              itemCount: itemCount,
              itemBuilder: itemBuilder,
            ),
          ),
      ],
    );
  }
}
