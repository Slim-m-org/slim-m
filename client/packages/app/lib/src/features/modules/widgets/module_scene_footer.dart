// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The status line, inline error and control row under a module scene.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'module_scene.dart';
import 'module_scene_controls.dart';
import 'module_scene_expand.dart';

class ModuleSceneFooter extends StatelessWidget {
  const ModuleSceneFooter({
    super.key,
    required this.scene,
    required this.tokens,
    required this.error,
    required this.onDismissError,
    required this.playing,
    required this.onTogglePlay,
    required this.onAction,
    this.onExpand,
  });

  final ModuleScene scene;
  final AppTokens tokens;
  final String? error;
  final VoidCallback onDismissError;
  final bool playing;
  final VoidCallback onTogglePlay;
  final void Function(String action) onAction;
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final status = scene.status;
    final error = this.error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (status != null) ...[
          const SizedBox(height: AppSpacing.s8),
          Text(
            status,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(
              fontFamily: AppFonts.mono,
              color: tokens.textSecondary,
            ),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(message: error, onDismiss: onDismissError),
        ],
        if (scene.controls.isNotEmpty || onExpand != null) ...[
          const SizedBox(height: AppSpacing.s8),
          // Wraps because a Row overflowed on a phone and clipped what sat last: the full-screen button.
          Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            children: [
              ...sceneControls(
                controls: scene.controls,
                playing: playing,
                onTogglePlay: onTogglePlay,
                onAction: onAction,
              ),
              if (onExpand case final expand?)
                SceneExpandButton(onExpand: expand),
            ],
          ),
        ],
      ],
    );
  }
}
