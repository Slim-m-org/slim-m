// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call header's way to open a module's call scene (decision 0133).
///
/// One scene on offer is one button. Several are a menu on the same button,
/// anchored above it at pointer width and a sheet at touch width
/// (desktop-vs-mobile.md, surface rule 1 and law 1).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/context_menu_region.dart';
import '../providers/module_rooms.dart';
import 'call_scene_stage.dart';

class CallSceneLauncher extends ConsumerStatefulWidget {
  const CallSceneLauncher({super.key, required this.channelId});

  final String channelId;

  @override
  ConsumerState<CallSceneLauncher> createState() => _CallSceneLauncherState();
}

class _CallSceneLauncherState extends ConsumerState<CallSceneLauncher> {
  final _region = GlobalKey<ContextMenuRegionState>();

  @override
  Widget build(BuildContext context) {
    final offered = ref.watch(
      moduleRoomsProvider(widget.channelId).select((m) => m.callScenes),
    );
    if (offered.isEmpty) return const SizedBox.shrink();
    if (offered.length == 1) {
      final only = offered.single;
      return AppIconButton(
        icon: AppIcons.playing,
        semanticLabel: 'Open ${only.title}',
        tooltip: only.title,
        onPressed: () => _open(only),
      );
    }
    return ContextMenuRegion(
      key: _region,
      ownsFocusNode: false,
      enableLongPress: false,
      sheetSemanticLabel: 'Activities',
      itemsBuilder: (context, close) => [
        for (final scene in offered)
          AppMenuItem(
            label: scene.title,
            leading: AppIcons.playing,
            onTap: () {
              close();
              _open(scene);
            },
          ),
      ],
      child: AppIconButton(
        icon: AppIcons.playing,
        semanticLabel: 'Activities',
        tooltip: 'Activities',
        onPressed: () => _region.currentState?.toggle(),
      ),
    );
  }

  void _open(api.ModuleCallScene scene) =>
      openCallScene(ref, widget.channelId, scene.moduleId);
}
