// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Draws the declarative nodes a module returns for a slot.
///
/// Closed and data-only: only the node types in `slot/1` are drawn, from
/// design tokens, and anything else was already dropped by the api parser.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'module_slot_icons.dart';
import 'module_slot_progress.dart';

/// [inline] lays the top-level nodes out in one row, for a badge slot.
/// [source] is the module's id from the server, never text the module drew;
/// badges name it so they cannot pass for a built-in chip.
class ModuleSlotView extends StatelessWidget {
  const ModuleSlotView(
    this.item, {
    required this.source,
    super.key,
    this.inline = false,
  });

  final api.ModuleSlotItem item;
  final String source;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    if (item.nodes.isEmpty) {
      final fallback = item.fallback;
      if (fallback == null || fallback.isEmpty) return const SizedBox.shrink();
      return _SlotText(
        api.ModuleSlotText(fallback, tone: api.ModuleSlotTone.muted),
      );
    }
    return inline
        ? _SlotRow(item.nodes, source)
        : _SlotStack(item.nodes, source);
  }
}

Widget _draw(api.ModuleSlotNode node, String source) => switch (node) {
  api.ModuleSlotText() => _SlotText(node),
  api.ModuleSlotIcon() => _SlotIcon(node.name),
  api.ModuleSlotBadge() => _SlotBadge(node, source),
  api.ModuleSlotProgress() => ModuleSlotProgressBar(node),
  api.ModuleSlotRow() => _SlotRow(node.children, source),
  api.ModuleSlotStack() => _SlotStack(node.children, source),
};

class _SlotStack extends StatelessWidget {
  const _SlotStack(this.nodes, this.source);

  final List<api.ModuleSlotNode> nodes;
  final String source;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: AppSpacing.s4,
    children: [
      for (final node in nodes)
        node is api.ModuleSlotProgress
            ? SizedBox(width: double.infinity, child: _draw(node, source))
            : _draw(node, source),
    ],
  );
}

class _SlotRow extends StatelessWidget {
  const _SlotRow(this.nodes, this.source);

  final List<api.ModuleSlotNode> nodes;
  final String source;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: AppSpacing.s8,
    children: [
      for (final node in nodes)
        node is api.ModuleSlotIcon
            ? _draw(node, source)
            : Flexible(child: _draw(node, source)),
    ],
  );
}

class _SlotText extends StatelessWidget {
  const _SlotText(this.node);

  final api.ModuleSlotText node;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final color = switch (node.tone) {
      api.ModuleSlotTone.accent => tokens.accent,
      api.ModuleSlotTone.muted => tokens.textSecondary,
      api.ModuleSlotTone.normal => tokens.textPrimary,
    };
    return Text(
      node.text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: AppText.ui.copyWith(
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _SlotIcon extends StatelessWidget {
  const _SlotIcon(this.name);

  final String? name;

  @override
  Widget build(BuildContext context) {
    final glyph = moduleSlotIcon(name);
    if (glyph == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ExcludeSemantics(
      child: Icon(glyph, size: AppSizes.icon16, color: tokens.textSecondary),
    );
  }
}

class _SlotBadge extends StatelessWidget {
  const _SlotBadge(this.node, this.source);

  final api.ModuleSlotBadge node;
  final String source;

  @override
  Widget build(BuildContext context) {
    final origin = 'From $source';
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: Tooltip(
        message: origin,
        excludeFromSemantics: true,
        triggerMode: TooltipTriggerMode.longPress,
        child: AppBadge(
          variant: switch (node.tone) {
            api.ModuleSlotTone.accent => AppBadgeVariant.moduleAccent,
            api.ModuleSlotTone.muted => AppBadgeVariant.moduleMuted,
            api.ModuleSlotTone.normal => AppBadgeVariant.module,
          },
          label: node.text,
          markerIcon: AppIcons.dock,
          icon: moduleSlotIcon(node.icon),
          semanticLabel: '${node.text}, ${origin.toLowerCase()}',
        ),
      ),
    );
  }
}
