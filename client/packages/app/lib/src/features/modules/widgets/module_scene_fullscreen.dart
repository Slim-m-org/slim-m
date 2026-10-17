// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module scene on its own screen, with nothing else competing for the
/// pointer.
///
/// Inline, a scene is a child of the transcript's scroll view, and the two
/// want the same gestures. Flutter's arena hands a vertical drag to the
/// nearest `Scrollable`, so drawing on a grid works sideways and turns into a
/// scroll the moment the finger moves down the screen. That is the reported
/// trouble with dragging on game-of-life, and it is not a bug in the scene
/// view: an inline board that won every vertical drag would trap the reader
/// inside it whenever they tried to scroll past.
///
/// Giving the scene a route of its own resolves it rather than arbitrating
/// it. There is no scrollable here, so every drag belongs to the board, and
/// the board gets the whole window instead of the share
/// [ModuleSceneFrame] rations it inline.
///
/// State is not copied. The same [ModuleSceneRunner] runs here as inline, so
/// for a message-scoped scene every action stores and broadcasts exactly as
/// it would have, and the inline view picks the result up through
/// `messageExtrasProvider` while this is open and after it closes. Opening
/// this is a change of viewport, not a fork of the game.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import 'module_scene.dart';
import 'module_scene_view.dart';

/// Opens [initial] full screen, driven by [runCommand].
///
/// [title] names the module in the bar, so somebody who opened a board from a
/// long transcript can tell what they are looking at.
Future<void> showModuleSceneFullscreen(
  BuildContext context, {
  required ModuleScene initial,
  required ModuleSceneRunner runCommand,
  void Function(List<SceneNote> notes)? onNotes,
  String? title,
}) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (context) => ModuleSceneFullscreen(
        initial: initial,
        runCommand: runCommand,
        onNotes: onNotes,
        title: title,
      ),
    ),
  );
}

class ModuleSceneFullscreen extends StatelessWidget {
  const ModuleSceneFullscreen({
    super.key,
    required this.initial,
    required this.runCommand,
    this.onNotes,
    this.title,
  });

  final ModuleScene initial;
  final ModuleSceneRunner runCommand;
  final void Function(List<SceneNote> notes)? onNotes;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final name = title ?? 'Module';
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      label: '$name, full screen',
      explicitChildNodes: true,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) => Navigator.of(context).maybePop(),
            ),
          },
          // Autofocus so Escape works before anything inside has been clicked.
          child: Focus(
            autofocus: true,
            child: _scaffold(context, tokens, name),
          ),
        ),
      ),
    );
  }

  Widget _scaffold(BuildContext context, AppTokens tokens, String name) {
    return Scaffold(
      backgroundColor: tokens.surfaceBase,
      appBar: AppBar(
        backgroundColor: tokens.surfaceBase,
        surfaceTintColor: Colors.transparent,
        leading: AppIconButton(
          icon: AppIcons.collapse,
          semanticLabel: 'Leave full screen',
          tooltip: 'Leave full screen',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          name,
          style: AppText.body.copyWith(
            color: tokens.textPrimary,
            fontWeight: AppWeights.semi,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: Center(
            child: ModuleSceneView(
              initial: initial,
              runCommand: runCommand,
              onNotes: onNotes,
              // The whole point: no cell cap, no share, no expand control.
              fillAvailable: true,
            ),
          ),
        ),
      ),
    );
  }
}
