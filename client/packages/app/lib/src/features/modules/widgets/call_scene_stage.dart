// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module's call scene on the call's stage (decision 0133): the `scene/1`
/// the module drew from its room state, painted by the module scene view, with
/// each tap or control sent as the room's next input.
///
/// The scene arrives with the state, from the room route, the `module.room`
/// frame or this viewer's own answer, so everyone in the call paints the same
/// one at the same `seq`. A refused move shows the module's reason under the
/// board; a room that failed to open or ended shows that in the card instead.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/call_scene_choice.dart';
import '../providers/module_rooms.dart';
import 'module_scene.dart';
import 'module_scene_view.dart';

/// The input that opens a module's call scene: the module answers its board as it is.
const callSceneOpenInput = '';

/// How much taller than the board the stage tile is, for the title and the controls.
const _chromeShare = 0.3;

String? _lastText;
ModuleScene? _lastScene;

/// [text] as a scene, parsed once however many widgets ask for the same frame.
ModuleScene? roomScene(String? text) {
  if (text == null) return null;
  if (text != _lastText) {
    _lastText = text;
    _lastScene = parseModuleScene(text);
  }
  return _lastScene;
}

/// The stage tile's width over height for [scene], or the stage's own default without one.
double callSceneAspect(ModuleScene? scene) {
  if (scene == null || scene.viewHeight <= 0) return 16 / 9;
  return scene.viewWidth / (scene.viewHeight * (1 + _chromeShare));
}

/// Opens [moduleId]'s call scene for this viewer, starting its room when it has none.
void openCallScene(WidgetRef ref, String channelId, String moduleId) {
  ref.read(callSceneChoiceProvider(channelId).notifier).open(moduleId);
  final rooms = ref.read(moduleRoomsProvider(channelId));
  if (rooms.room(moduleId) == null && !rooms.sending.contains(moduleId)) {
    unawaited(
      ref
          .read(moduleRoomsProvider(channelId).notifier)
          .send(moduleId, callSceneOpenInput),
    );
  }
}

class CallSceneStage extends ConsumerWidget {
  const CallSceneStage({
    super.key,
    required this.channelId,
    required this.scene,
  });

  final String channelId;
  final api.ModuleCallScene scene;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final moduleId = scene.moduleId;
    final rooms = ref.watch(moduleRoomsProvider(channelId));
    final drawn = roomScene(rooms.room(moduleId)?.scene);
    return Semantics(
      container: true,
      label: scene.title,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s12),
        decoration: BoxDecoration(
          color: tokens.surfaceSunken,
          border: Border.all(color: tokens.borderSubtle),
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Title(
              title: scene.title,
              tokens: tokens,
              onClose: () => ref
                  .read(callSceneChoiceProvider(channelId).notifier)
                  .close(moduleId),
            ),
            const SizedBox(height: AppSpacing.s8),
            Expanded(
              child: drawn == null
                  ? _NoBoard(
                      rooms: rooms,
                      moduleId: moduleId,
                      tokens: tokens,
                      onOpen: () => openCallScene(ref, channelId, moduleId),
                    )
                  : ModuleSceneView(
                      key: ValueKey(moduleId),
                      initial: drawn,
                      fillAvailable: true,
                      runCommand: (packed) => _sendMove(ref, packed),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// The scene view packs its action with a state the room keeps itself, so only the action is sent.
  Future<api.RunModuleCommandResult> _sendMove(
    WidgetRef ref,
    String packed,
  ) async {
    final decoded = jsonDecode(packed);
    final action = decoded is Map && decoded['action'] is String
        ? decoded['action'] as String
        : callSceneOpenInput;
    final rooms = moduleRoomsProvider(channelId);
    final result = await ref.read(rooms.notifier).send(scene.moduleId, action);
    if (result == null) {
      final notice = ref.read(rooms).notices[scene.moduleId];
      return api.RunModuleCommandResult(
        ok: false,
        error: notice ?? 'Could not send this move.',
      );
    }
    if (!result.applied || result.scene == null) {
      return api.RunModuleCommandResult(
        ok: false,
        error: result.reason ?? result.error,
      );
    }
    return api.RunModuleCommandResult(ok: true, output: result.scene);
  }
}

class _Title extends StatelessWidget {
  const _Title({
    required this.title,
    required this.tokens,
    required this.onClose,
  });

  final String title;
  final AppTokens tokens;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(
        AppIcons.playing,
        size: AppSizes.icon16,
        color: tokens.textSecondary,
      ),
      const SizedBox(width: AppSpacing.s8),
      Expanded(
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption.copyWith(
            color: tokens.textPrimary,
            fontWeight: AppWeights.medium,
          ),
        ),
      ),
      AppIconButton(
        icon: AppIcons.dismiss,
        semanticLabel: 'Close $title',
        tooltip: 'Close for me',
        onPressed: onClose,
      ),
    ],
  );
}

/// The card while there is no board: opening, failed to open, or over.
class _NoBoard extends StatelessWidget {
  const _NoBoard({
    required this.rooms,
    required this.moduleId,
    required this.tokens,
    required this.onOpen,
  });

  final ModuleRoomsModel rooms;
  final String moduleId;
  final AppTokens tokens;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    if (rooms.sending.contains(moduleId)) {
      return const Center(child: AppSpinner(size: AppSpinnerSize.md));
    }
    final notice = rooms.notices[moduleId];
    if (notice != null) {
      return Center(
        child: AppErrorState(message: notice, onRetry: onOpen),
      );
    }
    final held = rooms.room(moduleId) != null;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.s12,
        children: [
          Text(
            held ? 'Nothing to show yet.' : 'Not running.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          if (!held)
            AppButton(
              label: 'Start',
              size: AppButtonSize.sm,
              onPressed: onOpen,
            ),
        ],
      ),
    );
  }
}
