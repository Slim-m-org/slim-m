// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// Discovering and running an installed module's command, per
/// `docs/decisions/0021-modules-and-the-dock.md`'s module-agnostic
/// principle: this client offers no UI hardcoded to a module id, only a
/// general "run this fenced code block through whatever runner discovery
/// hands back" affordance.
extension SlimmApiModuleCommands on SlimmApi {
  /// Every code-block runner this caller may currently use, possibly empty -
  /// an empty list means no installed and enabled module declares one the
  /// caller holds the permission for, so no Run affordance should be shown.
  Future<List<CodeBlockRunner>> listCodeBlockRunners() async {
    final json = await _send('GET', '/modules/code-block-runners');
    return (json as List<dynamic>)
        .map((r) => CodeBlockRunner.fromJson(r as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Every slash command this caller may currently use in the composer,
  /// possibly empty - an empty list means no installed and enabled module
  /// declares a `slash-command` the caller holds the permission for.
  Future<List<SlashCommand>> listSlashCommands() async {
    final json = await _send('GET', '/modules/slash-commands');
    return (json as List<dynamic>)
        .map((c) => SlashCommand.fromJson(c as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Every app this caller may currently launch into a channel, possibly
  /// empty - an empty list means no installed and enabled module declares an
  /// `app` extension point the caller holds the permission for.
  Future<List<App>> listApps() async {
    final json = await _send('GET', '/modules/apps');
    return (json as List<dynamic>)
        .map((a) => App.fromJson(a as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Runs [moduleId]'s [command] with [input], returning the module ABI's
  /// own outcome. Requires the module to be installed, enabled, and the
  /// caller to hold the permission the command declared.
  ///
  /// [channelId] is the channel the command was typed in; only then may the
  /// module post a message, and only into that channel.
  ///
  /// With [postOutput] the server posts a successful run's output into
  /// [channelId] as the caller, labelled as the module's, and answers with the
  /// new message's id instead of the text; [replyToId] is the message it
  /// answers.
  Future<RunModuleCommandResult> runModuleCommand({
    required String moduleId,
    required String command,
    required String input,
    String? channelId,
    bool postOutput = false,
    String? replyToId,
  }) async {
    final json = await _send(
      'POST',
      '/modules/$moduleId/commands/$command',
      body: {
        'input': input,
        if (channelId != null) 'channel_id': channelId,
        if (postOutput) 'post_output': true,
        if (postOutput && replyToId != null) 'reply_to_id': replyToId,
      },
    );
    return RunModuleCommandResult.fromJson(json as Map<String, dynamic>);
  }
}
