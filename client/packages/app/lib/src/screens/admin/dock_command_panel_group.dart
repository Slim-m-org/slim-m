// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a module's `command` extension points lay out on its Dock screen.
///
/// A module declaring a handful of commands used to get one full
/// [DockCommandPanel] per command, stacked without end - a module with five
/// commands made a five-panel-tall settings screen with no way to group,
/// collapse or tab between them. At or under [collapseThreshold] that stack
/// is still the whole point (there is nothing to save room from), so it is
/// unchanged; past it, only one panel is ever open at a time and the rest
/// collapse to a single summary row, bounding the screen's height to one
/// open command regardless of how many the module declares.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/settings_section_header.dart';
import 'dock_command_panel.dart';

class DockCommandPanelGroup extends StatefulWidget {
  const DockCommandPanelGroup({
    super.key,
    required this.moduleId,
    required this.extensionPoints,
  });

  final String moduleId;
  final List<api.DockExtensionPoint> extensionPoints;

  /// Chosen because 1-3 full panels is already a screen a scroll finishes
  /// quickly; a 2026-09-24 audit of the addons repo found no shipped module
  /// past this, so it is a real ceiling rather than a number sized to no use.
  static const collapseThreshold = 3;

  @override
  State<DockCommandPanelGroup> createState() => _DockCommandPanelGroupState();
}

class _DockCommandPanelGroupState extends State<DockCommandPanelGroup> {
  /// Which command is open, or null. Reset per module (a new [widget.moduleId]
  /// means a fresh screen) rather than carried across, so opening a second
  /// module's screen never starts on a stale command index.
  int? _expanded;

  @override
  void didUpdateWidget(DockCommandPanelGroup old) {
    super.didUpdateWidget(old);
    if (old.moduleId != widget.moduleId) _expanded = null;
  }

  @override
  Widget build(BuildContext context) {
    final commands = widget.extensionPoints;
    if (commands.length <= DockCommandPanelGroup.collapseThreshold) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final ep in commands)
            DockCommandPanel(moduleId: widget.moduleId, extensionPoint: ep),
        ],
      );
    }
    return SettingsSectionCard(
      title: 'Commands',
      children: [
        for (final (index, ep) in commands.indexed) ...[
          _CommandSummaryRow(
            extensionPoint: ep,
            expanded: index == _expanded,
            onTap: () => setState(() {
              _expanded = index == _expanded ? null : index;
            }),
          ),
          if (index == _expanded)
            DockCommandPanel(
              moduleId: widget.moduleId,
              extensionPoint: ep,
              bare: true,
            ),
        ],
      ],
    );
  }
}

/// One command's collapsed row: its name, description and an expand chevron
/// that also serves as the way back to collapsed once open.
class _CommandSummaryRow extends StatelessWidget {
  const _CommandSummaryRow({
    required this.extensionPoint,
    required this.expanded,
    required this.onTap,
  });

  final api.DockExtensionPoint extensionPoint;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppListRow(
      label: extensionPoint.name,
      subtitle: extensionPoint.description,
      trailing: Icon(
        expanded ? AppIcons.chevronDown : AppIcons.chevronRight,
        size: AppSizes.icon16,
        color: tokens.textSecondary,
      ),
      onTap: onTap,
      semanticLabel: expanded
          ? 'Collapse ${extensionPoint.name}'
          : 'Expand ${extensionPoint.name}',
    );
  }
}
