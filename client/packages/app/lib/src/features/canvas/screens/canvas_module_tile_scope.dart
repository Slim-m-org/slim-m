// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the canvas pane hands the parts of its tree that show or place module tiles, without threading it through every layer between.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/canvas_module_tiles.dart';

class CanvasModuleTileScope extends InheritedWidget {
  const CanvasModuleTileScope({
    super.key,
    required this.channelId,
    required this.onPlace,
    required super.child,
  });

  final String channelId;

  /// Places a tile at the middle of the view; null while this viewer cannot draw.
  final ValueChanged<api.CanvasTileOffer>? onPlace;

  static CanvasModuleTileScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CanvasModuleTileScope>();

  @override
  bool updateShouldNotify(CanvasModuleTileScope oldWidget) =>
      channelId != oldWidget.channelId || onPlace != oldWidget.onPlace;

  /// One "Add" row per tile the viewer may place, for a canvas menu; [open] closes the menu and runs the placement.
  static Widget menuItems({required void Function(VoidCallback place) open}) =>
      Consumer(
        builder: (context, ref, _) {
          final scope = maybeOf(context);
          final offers =
              ref.watch(canvasTileOffersProvider).valueOrNull ?? const [];
          if (scope == null || offers.isEmpty) return const SizedBox.shrink();
          final place = scope.onPlace;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final offer in offers)
                AppMenuItem(
                  label: 'Add ${offer.tile}',
                  leading: AppIcons.dock,
                  onTap: place == null ? null : () => open(() => place(offer)),
                ),
            ],
          );
        },
      );
}
