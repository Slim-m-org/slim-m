// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock's one More button: every optional call control that is not pinned
/// to the dock, and the list that pins them there (kept per device in the voice
/// settings). A popover on a wide window, a sheet on a compact one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/control_menu_entries.dart';
import '../../../widgets/control_swatch_row.dart' show ControlOptionEntry;
import '../../../widgets/control_options_menu.dart';
import '../../canvas/providers/canvas_toggle_refocus.dart';
import '../providers/voice_settings_controller.dart';
import 'call_device_options.dart' show callMenuWidth;
import 'dock_item.dart';
import 'dock_items.dart' show DockSplit;
import 'dock_menu_button.dart';

class DockMoreButton extends ConsumerStatefulWidget {
  const DockMoreButton({super.key, required this.split});

  /// What the menu lists and what "Show in dock" can pin.
  final DockSplit split;

  @override
  ConsumerState<DockMoreButton> createState() => _DockMoreButtonState();
}

class _DockMoreButtonState extends ConsumerState<DockMoreButton> {
  final _scope = FocusNode(skipTraversal: true, debugLabel: 'dock more');

  /// The ids the menu listed when it opened, so a toggle inside it (captions on, a pin) cannot pull its own row out from under the pointer.
  ({Set<String> inMore, Set<String> pinnable})? _openIds;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !ref.read(canvasToggleRefocusProvider)) return;
      ref.read(canvasToggleRefocusProvider.notifier).state = false;
      final button = _scope.descendants.where((n) => n.canRequestFocus);
      if (button.isNotEmpty) button.first.requestFocus();
    });
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _scope,
      canRequestFocus: false,
      child: DockMenuButton(
        icon: AppIcons.moreHorizontal,
        tooltip: 'More',
        sheetLabel: 'More call controls',
        menuWidth: callMenuWidth,
        onOpenChanged: (open) => _openIds = open
            ? (
                inMore: {for (final i in widget.split.inMore) i.id},
                pinnable: {for (final i in widget.split.pinnable) i.id},
              )
            : null,
        itemsBuilder: (context, close) => [
          for (final entry in _entries())
            ...controlOptionRows(context, entry, close, callMenuWidth),
        ],
      ),
    );
  }

  List<ControlOptionEntry> _entries() {
    final open = _openIds;
    List<DockItem> listed(List<DockItem> live, Set<String>? frozen) => [
      for (final item in widget.split.items)
        if (frozen?.contains(item.id) ?? live.contains(item)) item,
    ];
    final inMore = listed(widget.split.inMore, open?.inMore);
    final pinnable = listed(widget.split.pinnable, open?.pinnable);
    return [
      for (final item in inMore) ...item.entries,
      if (inMore.isNotEmpty && pinnable.isNotEmpty)
        const ControlOptionDivider(),
      if (pinnable.isNotEmpty)
        ControlSubmenu(
          label: 'Show in dock',
          icon: AppIcons.pin,
          panel: (context, close) => _PinList(items: pinnable),
        ),
    ];
  }
}

class _PinList extends ConsumerWidget {
  const _PinList({required this.items});

  final List<DockItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinned = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.dockPinned),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in items)
          AppMenuSwitchRow(
            label: item.name,
            value: pinned.contains(item.id),
            onChanged: (next) => unawaited(
              ref
                  .read(voiceSettingsControllerProvider.notifier)
                  .setDockPinned(item.id, next),
            ),
          ),
      ],
    );
  }
}
