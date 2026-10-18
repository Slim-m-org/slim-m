// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Running a module slash command on send, kept out of the composer's own
/// State so the whole send-a-`/command` path is one testable function rather
/// than more lines on an already-large widget.
///
/// The host posts the module's output itself, as the member but labelled as the
/// module's, so a module cannot make its text pass for the member's own words.
/// A failure - a 403, or the module's own error - posts nothing and reports
/// through [fail], leaving the `/command` text in the field to retry.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../api_failure.dart';
import '../../modules/providers/app_launch.dart';
import '../../../providers/providers.dart';
import '../providers/slash_command.dart';
import '../../modules/widgets/app_launcher_sheet.dart';

/// Runs [command] with [args] and applies the outcome: on success clears the
/// field, and calls [onPosted] when the host posted a message; on any failure,
/// calls [fail] with a human message.
///
/// [controller] belongs to the composer's parent and is disposed with it, so
/// the round trip can outlive it: once [isMounted] is false nothing here
/// touches the field, the same guard every other post-await write in the
/// composer already carries.
Future<void> sendSlashCommand({
  required SlimmApi api,
  required SlashCommand command,
  required String args,
  required String channelId,
  required TextEditingController controller,
  required bool Function() isMounted,
  required void Function() onPosted,
  required void Function(String message) fail,
  String? replyToId,
}) async {
  try {
    final result = await api.runModuleCommand(
      moduleId: command.moduleId,
      command: command.command,
      input: args,
      channelId: channelId,
      postOutput: true,
      replyToId: replyToId,
    );
    if (!isMounted()) return;
    if (result.ok) {
      controller.clear();
      if (result.messageId != null) onPosted();
    } else {
      fail(result.error ?? 'The command did not run.');
    }
  } on ApiException catch (e) {
    fail(describeApiFailure('run /${command.name}', e));
  }
}

/// Runs whatever command the composed text names, answering whether it took
/// the send. False means the text is an ordinary message and the caller should
/// post it itself.
///
/// The two command paths and the ordinary send were interleaved in
/// `Composer._send`, which is how [hasStagedFile] came to be missed: neither
/// command path carries an attachment - [launchApp] takes none and the slash
/// run posts no files - and neither cleared the staging list, so a command
/// typed with a file staged went out without it and said nothing. Refused
/// here instead, before either path can run.
Future<bool> runComposedCommand({
  required WidgetRef ref,
  required String channelId,
  required TextEditingController controller,
  required List<App> apps,
  required List<SlashCommand> commands,
  required bool hasStagedFile,
  required bool Function() isMounted,
  required void Function() clearError,
  required void Function() onPosted,
  required void Function(String message) fail,
  String? replyToId,
}) async {
  // An app wins its own keyword, so it is matched before the command run.
  final app = matchApp(apps, controller.text);
  final clash = clashingSlashKeyword(commands, controller.text);
  if (app == null && clash != null) {
    fail(
      'Two modules both provide /$clash, so it will not run. Disable one in Modules.',
    );
    return true;
  }
  final match = matchSlashCommand(commands, controller.text);
  if (app == null && match == null) return false;
  if (hasStagedFile) {
    fail(
      'A command cannot carry an attachment. Send the file on its own, or remove it first.',
    );
    return true;
  }
  clearError();
  if (app != null) {
    final launched = await launchApp(
      ref: ref,
      channelId: channelId,
      app: app,
      onError: fail,
    );
    if (launched && isMounted()) controller.clear();
    return true;
  }
  await sendSlashCommand(
    api: ref.read(apiProvider),
    command: match!.$1,
    args: match.$2,
    channelId: channelId,
    controller: controller,
    isMounted: isMounted,
    onPosted: onPosted,
    fail: fail,
    replyToId: replyToId,
  );
  return true;
}
