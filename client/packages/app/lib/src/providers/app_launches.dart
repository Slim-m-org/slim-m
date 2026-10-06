// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The first run of each app message, kept outside the widget that asked for it.
///
/// A message row is rebuilt and remounted as a transcript scrolls. When the
/// launch lived in the row's own state, every remount of a message nobody had
/// a stored frame for sent the launch again, and a refused launch (no
/// permission, rate limited) was refused again each time, behind a spinner
/// that never resolved. Here one message launches at most once until the
/// viewer presses Retry.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../api_failure.dart';
import 'providers.dart';

/// Where one message's launch stands: in flight, answered, or refused.
class AppLaunch {
  const AppLaunch.running() : error = null, result = null, running = true;
  const AppLaunch.answered(this.result) : error = null, running = false;
  const AppLaunch.refused(this.error) : result = null, running = false;

  final bool running;
  final String? error;
  final api.RunModuleCommandResult? result;
}

class AppLaunches extends Notifier<Map<String, AppLaunch>> {
  @override
  Map<String, AppLaunch> build() => const {};

  /// Launches [messageId]'s app unless it already has a launch on record;
  /// [retry] is the viewer's own press and replaces a refusal.
  Future<void> launch(
    String messageId,
    api.AppSurface surface, {
    bool retry = false,
  }) async {
    final current = state[messageId];
    if (current != null && (current.running || !retry)) return;
    state = {...state, messageId: const AppLaunch.running()};
    AppLaunch outcome;
    try {
      final result = await ref
          .read(apiProvider)
          .runCodeBlock(
            messageId: messageId,
            blockIndex: appBlockIndex,
            moduleId: surface.moduleId,
            command: surface.command,
            // A launch takes no argument; a well-behaved app returns its initial frame for empty input.
            input: '',
          );
      outcome = AppLaunch.answered(result);
    } on api.ApiException catch (e) {
      outcome = AppLaunch.refused(describeApiFailure('launch this app', e));
    } catch (_) {
      // Anything else must still end the spinner, or Retry is ignored for good.
      outcome = const AppLaunch.refused(
        'Could not launch this app. Try again in a moment.',
      );
    }
    state = {...state, messageId: outcome};
  }
}

final appLaunchesProvider =
    NotifierProvider<AppLaunches, Map<String, AppLaunch>>(AppLaunches.new);

/// The fenced-block index an app surface stores its shared state at. An app
/// message has no fenced blocks, so block 0 is always free and always its.
const appBlockIndex = 0;
