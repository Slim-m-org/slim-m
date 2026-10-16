// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A launched app, rendered inline in its message as the module's interactive,
/// shared surface. The message says only which `(moduleId, command)` it
/// launched (see [api.AppSurface]); the surface itself is the module's own
/// output, run and stored against this message's block 0 through the shared
/// code-run route - exactly the machinery a run fenced code block uses, so
/// every viewer sees the same evolving surface and every step is shared.
///
/// This file names no module: it launches whatever the message carries and
/// renders whatever comes back, per docs/decisions/0021-modules-and-the-dock's
/// module-agnostic principle. A non-scene output still renders, as text, the
/// same way [ModuleCommandOutput] handles any command result.
///
/// On mount, if no run is stored yet, it runs the command once (empty input, so
/// a well-behaved app returns its initial frame); a later viewer just reads the
/// stored run. Every follow-up action (step, tap, play) goes back through the
/// same shared route from within [ModuleCommandOutput].
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/app_launches.dart';
import '../providers/message_extras.dart';
import 'module_command_output.dart';

class AppSurfaceView extends ConsumerStatefulWidget {
  const AppSurfaceView({
    super.key,
    required this.messageId,
    required this.surface,
    required this.title,
  });

  final String messageId;
  final api.AppSurface surface;

  /// A human label for the app, shown as the surface's header. Falls back to
  /// the module id when discovery has no friendlier name.
  final String title;

  @override
  ConsumerState<AppSurfaceView> createState() => _AppSurfaceViewState();
}

class _AppSurfaceViewState extends ConsumerState<AppSurfaceView> {
  api.CodeRun? _sharedRun() {
    final runs =
        ref.watch(
          messageExtrasProvider.select((m) => m[widget.messageId]?.codeRuns),
        ) ??
        const <api.CodeRun>[];
    for (final run in runs) {
      if (run.blockIndex == appBlockIndex) return run;
    }
    return null;
  }

  void _launch({bool retry = false}) => unawaited(
    ref
        .read(appLaunchesProvider.notifier)
        .launch(widget.messageId, widget.surface, retry: retry),
  );

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final sharedRun = _sharedRun();
    final launch = ref.watch(
      appLaunchesProvider.select((m) => m[widget.messageId]),
    );
    // First viewer with no stored run kicks it off once; the broadcast then feeds every viewer, including this one, through the shared cache.
    if (sharedRun == null && launch == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _launch();
      });
    }

    // Hugs its content: a game is as wide as its board plus the padding, not the message.
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s8),
        decoration: BoxDecoration(
          color: tokens.surfaceSunken,
          border: Border.all(color: tokens.borderSubtle),
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  AppIcons.dock,
                  size: AppSizes.icon16,
                  color: tokens.textSecondary,
                ),
                const SizedBox(width: AppSpacing.s4),
                Text(
                  widget.title,
                  style: AppText.micro.copyWith(color: tokens.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s8),
            if (sharedRun != null)
              _output(_asResult(sharedRun))
            else if (launch?.result case final answered?)
              _output(answered)
            else if (launch?.error case final error?)
              AppErrorState(message: error, onRetry: () => _launch(retry: true))
            else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.s8),
                child: SizedBox(
                  width: AppSizes.icon20,
                  height: AppSizes.icon20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _output(api.RunModuleCommandResult result) => ModuleCommandOutput(
    result: result,
    moduleId: widget.surface.moduleId,
    command: widget.surface.command,
    messageId: widget.messageId,
    blockIndex: appBlockIndex,
  );

  /// A [CodeRun]'s single `output` is the module's output when it succeeded, or
  /// its error otherwise - the same split [ModuleCommandOutput] renders.
  static api.RunModuleCommandResult _asResult(api.CodeRun run) =>
      api.RunModuleCommandResult(
        ok: run.ok,
        output: run.ok ? run.output : null,
        error: run.ok ? null : run.output,
      );
}
