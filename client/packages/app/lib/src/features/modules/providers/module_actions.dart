// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The module and code-block runs the module and message widgets make, so none of them talks to REST.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/providers.dart';

class ModuleActions {
  const ModuleActions(this._api);

  final SlimmApi _api;

  Future<Message> launchAppMessage({
    required String channelId,
    required String id,
    required String moduleId,
    required String command,
    String? content,
  }) => _api.launchAppMessage(
    channelId: channelId,
    id: id,
    moduleId: moduleId,
    command: command,
    content: content,
  );

  Future<RunModuleCommandResult> runCodeBlock({
    required String messageId,
    required int blockIndex,
    required String moduleId,
    required String command,
    required String input,
  }) => _api.runCodeBlock(
    messageId: messageId,
    blockIndex: blockIndex,
    moduleId: moduleId,
    command: command,
    input: input,
  );

  Future<RunModuleCommandResult> runModuleCommand({
    required String moduleId,
    required String command,
    required String input,
    String? channelId,
    bool postOutput = false,
    String? replyToId,
  }) => _api.runModuleCommand(
    moduleId: moduleId,
    command: command,
    input: input,
    channelId: channelId,
    postOutput: postOutput,
    replyToId: replyToId,
  );
}

final moduleActionsProvider = Provider(
  (ref) => ModuleActions(ref.watch(apiProvider)),
);
