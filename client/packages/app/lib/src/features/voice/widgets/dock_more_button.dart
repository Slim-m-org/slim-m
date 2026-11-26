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
import 'dock_menu_button.dart';

class DockMoreButton extends ConsumerStatefulWidget {
  const DockMoreButton({
    super.key,
    required this.inMore,
    required this.pinnable,
  });

  /// The items the menu lists.
  final List<DockItem> inMore;

  /// The items the "Show in dock" list can pin.
  final List<DockItem> pinnable;

  @override
  ConsumerState<DockMoreButton> createState() => _DockMoreButtonState();
}

class _DockMoreButtonState extends ConsumerState<DockMoreButton> {
  final _scope = FocusNode(skipTraversal: true, debugLabel: 'dock more');

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
        itemsBuilder: (context, close) => [
          for (final entry in _entries())
            ...controlOptionRows(context, entry, close, callMenuWidth),
        ],
      ),
    );
  }

  List<ControlOptionEntry> _entries() => [
    for (final item in widget.inMore) ...item.entries,
    if (widget.inMore.isNotEmpty && widget.pinnable.isNotEmpty)
      const ControlOptionDivider(),
    if (widget.pinnable.isNotEmpty)
      ControlSubmenu(
        label: 'Show in dock',
        icon: AppIcons.pin,
        panel: (context, close) => _PinList(items: widget.pinnable),
      ),
  ];
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
