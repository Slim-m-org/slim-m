// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a sheet's own header needs to know about how it is presented.
library;

import 'package:flutter/material.dart';

import '../../app_icons.dart';
import '../core/icon_button.dart';

/// Marks a subtree shown as a desktop dialog by `showAppSheet`, where there is
/// no handle to close it with.
class SheetDialogScope extends InheritedWidget {
  const SheetDialogScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SheetDialogScope>() != null;

  @override
  bool updateShouldNotify(SheetDialogScope oldWidget) => false;
}

/// The close button of a desktop sheet dialog; nothing on a phone sheet, whose
/// handle, drag and system back already close it.
class AppSheetCloseButton extends StatelessWidget {
  const AppSheetCloseButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (!SheetDialogScope.of(context)) return const SizedBox.shrink();
    return AppIconButton(
      icon: AppIcons.dismiss,
      semanticLabel: 'Close',
      tooltip: 'Close',
      onPressed: () => Navigator.of(context).maybePop(),
    );
  }
}
