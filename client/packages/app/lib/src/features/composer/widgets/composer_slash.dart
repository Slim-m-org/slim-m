// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Running a module slash command on send, kept out of the composer's own
/// State so the whole send-a-`/command` path is one testable function rather
/// than more lines on an already-large widget.
///
/// A module is a pure function; there is no bot identity to post as, so the
/// module's own output becomes the composed text and goes out as an ordinary
/// message through the composer's existing send path ([post]). A failure - a
/// 403, or the module's own error - posts nothing and reports through [fail],
/// leaving the `/command` text in the field to retry.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../api_failure.dart';
import '../../modules/providers/app_launch.dart';
import '../../../providers/providers.dart';
import '../providers/slash_command.dart';
import '../../modules/widgets/app_launcher_sheet.dart';

/// Runs [command] with [args] and applies the outcome: on a non-empty result,
/// replaces the field text with it and [post]s; on an empty-but-ok result,
/// clears the field; on any failure, calls [fail] with a human message.
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
  required Future<void> Function() post,
  required void Function(String message) fail,
}) async {
  try {
    final result = await api.runModuleCommand(
      moduleId: command.moduleId,
      command: command.command,
      input: args,
      channelId: channelId,
    );
    if (!isMounted()) return;
    final output = result.output;
    if (result.ok && output != null && output.trim().isNotEmpty) {
      controller.text = output;
      await post();
    } else if (result.ok) {
      controller.clear();
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
/// run posts through `post()` with an empty list - and neither cleared the
/// staging list, so a command typed with a file staged went out without it and
/// said nothing. Refused here instead, before either path can run.
Future<bool> runComposedCommand({
  required WidgetRef ref,
  required String channelId,
  required TextEditingController controller,
  required List<App> apps,
  required List<SlashCommand> commands,
  required bool hasStagedFile,
  required bool Function() isMounted,
  required void Function() clearError,
  required Future<void> Function() post,
  required void Function(String message) fail,
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
    post: post,
    fail: fail,
  );
  return true;
}
