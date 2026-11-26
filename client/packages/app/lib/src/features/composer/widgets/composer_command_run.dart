// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the composer does with a typed `/command` on send, apart from the
/// ordinary message: `/gif` opens the picker, `/tts` speaks the line, and a
/// module command or app runs. Kept out of the composer's State so the whole
/// path is one class with its own in-flight flag.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show App, SlashCommand;

import '../../../ids.dart';
import 'composer_gif_command.dart';
import 'composer_slash.dart';
import 'composer_tts_command.dart';

class ComposerCommandRun {
  final _launchId = RetryId(newMessageId);

  /// True while a command awaits its result, so a second send cannot rerun it.
  bool running = false;

  /// Handles the command typed in [controller], if it is one. True when the
  /// send is finished here; false when the text is an ordinary message, which
  /// `/tts` leaves in the field as just its line.
  Future<bool> run({
    required WidgetRef ref,
    required String channelId,
    required TextEditingController controller,
    required List<App> apps,
    required List<SlashCommand> commands,
    required bool hasStagedFile,
    required bool gifSearchEnabled,
    required bool Function() isMounted,
    required void Function(String query) openGif,
    required void Function() clearError,
    required void Function() onPosted,
    required void Function(String message) fail,
    String? replyToId,
  }) async {
    final gifQuery = gifSearchEnabled && !hasStagedFile
        ? gifCommandQuery(controller.text)
        : null;
    if (gifQuery != null) {
      controller.clear();
      openGif(gifQuery);
      return true;
    }
    running = true;
    try {
      final spoken = await speakComposedTts(
        ref: ref,
        channelId: channelId,
        controller: controller,
        fail: fail,
      );
      if (!spoken) return true;
      return await runComposedCommand(
        ref: ref,
        launchId: _launchId,
        channelId: channelId,
        controller: controller,
        apps: apps,
        commands: commands,
        hasStagedFile: hasStagedFile,
        isMounted: isMounted,
        clearError: clearError,
        onPosted: onPosted,
        replyToId: replyToId,
        fail: fail,
      );
    } finally {
      running = false;
    }
  }
}
