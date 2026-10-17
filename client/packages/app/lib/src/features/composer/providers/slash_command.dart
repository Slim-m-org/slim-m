// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every module slash command this viewer may invoke from the composer: `GET
/// /modules/slash-commands`. An empty list means no installed and enabled
/// module declares a `slash-command` extension point the caller holds the
/// permission for - see docs/decisions/0021-modules-and-the-dock.md's
/// module-agnostic principle. The composer offers these as `/name` rows
/// alongside its own built-in text commands, and `matchSlashCommand` is how it
/// recognizes, on send, that a message is one to run rather than post.
///
/// Invalidated wherever module install/enable/disable or a module permission
/// grant/revoke succeeds - the same events `codeBlockRunnerProvider` watches,
/// since those are the only things that change what this answers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

final slashCommandProvider = FutureProvider.autoDispose<List<api.SlashCommand>>(
  (ref) => ref.watch(apiProvider).listSlashCommands(),
);

/// The module slash command [text] invokes and the arguments after its
/// keyword, or null when [text] is not `/name ...` for any known command.
///
/// A slash command is the whole message (`autocompleteQueryAt` only opens the
/// `/` trigger at offset zero), so this matches from the start: the first
/// token after `/` is the keyword, case-insensitive, and everything after the
/// first run of whitespace is the argument string handed to the module as-is.
///
/// A keyword offered by two different modules matches nothing: the server now
/// refuses to enable a second one, so this only guards a deployment that
/// already had the clash, where running an arbitrary one would be worse.
/// [clashingSlashKeyword] lets the composer say so instead of posting it.
(api.SlashCommand, String)? matchSlashCommand(
  List<api.SlashCommand> commands,
  String text,
) {
  final name = _keywordOf(text);
  if (name == null) return null;
  final matches = _withKeyword(commands, name);
  if (matches.isEmpty || _isClash(matches)) return null;
  final trimmed = text.trimLeft();
  final rest = trimmed.substring(1 + name.length);
  return (matches.first, rest.trim());
}

/// The keyword [text] types when two different modules offer it, else null.
String? clashingSlashKeyword(List<api.SlashCommand> commands, String text) {
  final name = _keywordOf(text);
  if (name == null) return null;
  return _isClash(_withKeyword(commands, name)) ? name : null;
}

bool _isClash(List<api.SlashCommand> matches) =>
    matches.any((command) => command.moduleId != matches.first.moduleId);

List<api.SlashCommand> _withKeyword(
  List<api.SlashCommand> commands,
  String name,
) => commands.where((c) => c.name.toLowerCase() == name).toList();

String? _keywordOf(String text) {
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith('/')) return null;
  final body = trimmed.substring(1);
  final match = RegExp(r'\s').firstMatch(body);
  final name = (match == null ? body : body.substring(0, match.start))
      .toLowerCase();
  return name.isEmpty ? null : name;
}
