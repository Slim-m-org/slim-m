// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Modules list's top row: the Installed / Browse filter and the overflow
/// menu that holds everything else (files, sources).
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../widgets/anchored_menu.dart';
import '../../../../widgets/animated_menu_portal.dart';

enum DockListFilter { installed, browse }

class DockPaneHeader extends StatefulWidget {
  const DockPaneHeader({
    super.key,
    required this.filter,
    required this.onFilter,
    required this.onInstallFile,
    required this.onAddSource,
    required this.onManageSources,
  });

  final DockListFilter filter;
  final ValueChanged<DockListFilter> onFilter;
  final VoidCallback onInstallFile;
  final VoidCallback onAddSource;
  final VoidCallback onManageSources;

  @override
  State<DockPaneHeader> createState() => _DockPaneHeaderState();
}

class _DockPaneHeaderState extends State<DockPaneHeader> {
  final _menu = AnimatedMenuController();

  VoidCallback _then(VoidCallback action) => () {
    _menu.hide();
    action();
  };

  @override
  Widget build(BuildContext context) => Row(
    spacing: AppSpacing.s8,
    children: [
      Expanded(
        child: Align(
          alignment: Alignment.centerLeft,
          child: AppSegmentedControl.inline(
            semanticLabel: 'Show modules',
            options: const [
              AppSegmentedOption(label: 'Installed'),
              AppSegmentedOption(label: 'Browse'),
            ],
            selectedIndex: widget.filter.index,
            onSegmentSelected: (i) => widget.onFilter(DockListFilter.values[i]),
          ),
        ),
      ),
      AnchoredMenu(
        controller: _menu,
        menu: AppMenu(
          width: 240,
          children: [
            AppMenuItem(
              label: 'Install from a file',
              leading: AppIcons.fileArchive,
              onTap: _then(widget.onInstallFile),
            ),
            AppMenuItem(
              label: 'Add a community source',
              leading: AppIcons.add,
              onTap: _then(widget.onAddSource),
            ),
            AppMenuItem(
              label: 'Manage sources',
              leading: AppIcons.settings,
              onTap: _then(widget.onManageSources),
            ),
          ],
        ),
        child: AppIconButton(
          icon: AppIcons.moreVertical,
          semanticLabel: 'Module options',
          onPressed: _menu.toggle,
        ),
      ),
    ],
  );
}
