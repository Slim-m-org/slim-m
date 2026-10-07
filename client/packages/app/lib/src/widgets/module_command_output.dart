// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One module command's result. When the module returned a scene (see
/// `module_scene.dart`), this paints it interactively; otherwise it shows the
/// output notebook-style: its own bordered panel, monospace, tinted for an
/// error rather than only labelled. Shared by [MessageCodeBlockRunner] and the
/// Dock's command panel so a module's output reads the same wherever it is
/// triggered from.
///
/// [moduleId] and [command] are what a scene needs to run its own follow-up
/// actions (step, tap, ...) back against the same module; without them a scene
/// still renders, just as a static first frame with no controls.
///
/// When [messageId] and [blockIndex] are given (a code block in a real
/// message), those follow-up actions go through the message-scoped, shared run
/// route, so every step/tap/play tick is stored and broadcast - everyone
/// viewing sees the same evolving scene, not a private copy. Without them (the
/// Dock command panel), the actions are the ephemeral per-caller run.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../audio/scene_sound_player.dart';
import '../providers/module_sound_settings.dart';
import '../providers/providers.dart';
import 'module_scene.dart';
import 'module_scene_fullscreen.dart';
import 'module_scene_view.dart';

class ModuleCommandOutput extends ConsumerWidget {
  const ModuleCommandOutput({
    super.key,
    required this.result,
    this.moduleId,
    this.command,
    this.messageId,
    this.blockIndex,
  });

  final api.RunModuleCommandResult result;
  final String? moduleId;
  final String? command;

  /// The message and fenced-block this output belongs to, so a scene's
  /// follow-up actions run through the shared, message-scoped route rather
  /// than the ephemeral one - see the class doc. Null for the Dock panel.
  final String? messageId;
  final int? blockIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final output = result.output;
    final moduleId = this.moduleId;
    final command = this.command;
    if (result.ok && output != null && moduleId != null && command != null) {
      final scene = parseModuleScene(output);
      if (scene != null) {
        final messageId = this.messageId;
        final blockIndex = this.blockIndex;
        // Shared when this scene belongs to a message: each action stores and broadcasts, so everyone watching sees the same evolving scene.
        final shared = messageId != null && blockIndex != null;
        // The full-screen route outlives this widget, so its closures hold the container, never ref.
        final container = ProviderScope.containerOf(context, listen: false);
        Future<api.RunModuleCommandResult> run(String input) => shared
            ? container
                  .read(apiProvider)
                  .runCodeBlock(
                    messageId: messageId,
                    blockIndex: blockIndex,
                    moduleId: moduleId,
                    command: command,
                    input: input,
                  )
            : container
                  .read(apiProvider)
                  .runModuleCommand(
                    moduleId: moduleId,
                    command: command,
                    input: input,
                  );
        // The other half of "never plays without interaction": see NotesOp's own doc comment for the full defence.
        void notes(List<SceneNote> played) {
          if (!container.read(moduleSoundSettingsProvider)) return;
          unawaited(
            container.read(moduleSoundPlayerProvider).playNotes(played),
          );
        }

        return ModuleSceneView(
          initial: scene,
          runCommand: run,
          onNotes: notes,
          // Only a message-scoped board has a screen of its own to go to.
          onExpand: shared
              ? () => showModuleSceneFullscreen(
                  context,
                  initial: scene,
                  runCommand: run,
                  onNotes: notes,
                  title: moduleId,
                )
              : null,
        );
      }
    }

    final isError = !result.ok;
    final text = (isError ? result.error : result.output) ?? '';
    // Recessed (sunken), not raised like the code block above it, so the result reads as the answer that came out of the code, not more code.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: AppSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: isError ? tokens.surfaceRaised : tokens.surfaceSunken,
        border: Border.all(
          color: isError ? tokens.dangerBorder : tokens.borderSubtle,
        ),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                AppIcons.forward,
                size: AppSizes.icon16,
                color: isError ? tokens.dangerText : tokens.textSecondary,
              ),
              const SizedBox(width: AppSpacing.s4),
              Text(
                isError ? 'Error' : 'Result',
                style: AppText.micro.copyWith(
                  fontFamily: AppFonts.mono,
                  color: isError ? tokens.dangerText : tokens.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          SelectableText(
            text,
            // 13/1.6 match AppCodeBlock's own fenced-block body exactly, so output reads as a continuation of the code above it, not a mismatched font.
            style: TextStyle(
              fontFamily: AppFonts.mono,
              fontSize: 13,
              height: 1.6,
              color: isError ? tokens.dangerText : tokens.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
