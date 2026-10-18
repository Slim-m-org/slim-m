// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Discovering and running an installed module's command, per
/// `docs/decisions/0021-modules-and-the-dock.md`'s module-agnostic
/// principle: nothing here knows what any command does, only that a
/// `(module_id, command)` pair exists and how to POST to it.
///
/// Split out of models.dart purely to stay under this repo's line budget.
library;

import 'models_dock_activity.dart';

/// One `(module_id, command)` pair this caller may POST to via
/// `runModuleCommand`, from `GET /modules/code-block-runners`.
/// A module `slash-command` extension point the caller may invoke from the
/// composer as `/name`. A plain mirror of the wire shape; the app layer
/// decides how to offer and run it.
class SlashCommand {
  const SlashCommand({
    required this.moduleId,
    required this.command,
    required this.name,
    this.description,
    this.module,
  });

  final String moduleId;
  final String command;

  /// The keyword the composer offers as `/name`.
  final String name;
  final String? description;

  /// The module behind it and what it may do; null from an older server.
  final ModuleInfo? module;

  factory SlashCommand.fromJson(Map<String, dynamic> json) => SlashCommand(
        moduleId: json['module_id'] as String,
        command: json['command'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        module: ModuleInfo.fromJson(json['module']),
      );
}

/// A module `app` extension point the caller may launch into a channel from
/// the composer's apps menu (or as a `/name` alias), from `GET /modules/apps`.
/// Launching one posts a message that renders as the module's interactive,
/// shared surface. A plain mirror of the wire shape.
class App {
  const App({
    required this.moduleId,
    required this.command,
    required this.name,
    this.description,
    this.module,
  });

  final String moduleId;
  final String command;

  /// What the composer's apps menu shows, and the `/name` keyword.
  final String name;
  final String? description;

  /// The module behind it and what it may do; null from an older server.
  final ModuleInfo? module;

  factory App.fromJson(Map<String, dynamic> json) => App(
        moduleId: json['module_id'] as String,
        command: json['command'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        module: ModuleInfo.fromJson(json['module']),
      );
}

class CodeBlockRunner {
  const CodeBlockRunner({
    required this.moduleId,
    required this.command,
    this.language,
  });

  final String moduleId;
  final String command;

  /// The fenced-block language this runner matches, or null for a wildcard
  /// that matches any block. The app layer normalizes case and applies its
  /// own alias map before comparing this against a block's own fence tag -
  /// this package stays a plain mirror of the wire shape.
  final String? language;

  factory CodeBlockRunner.fromJson(Map<String, dynamic> json) =>
      CodeBlockRunner(
        moduleId: json['module_id'] as String,
        command: json['command'] as String,
        language: json['language'] as String?,
      );
}

/// The module ABI's own outcome, echoed straight through by `POST
/// /modules/{moduleId}/commands/{command}`: either [output] on success, or
/// [error] - the module's own declared failure, or a clean description of a
/// host-level refusal (a resource limit, say). Never thrown as an API
/// exception: only a transport-level failure (network, permission, gating)
/// is.
class RunModuleCommandResult {
  const RunModuleCommandResult({
    required this.ok,
    this.output,
    this.error,
    this.messageId,
  });

  final bool ok;
  final String? output;
  final String? error;

  /// The message the output was posted as, when the run asked to post it.
  final String? messageId;

  factory RunModuleCommandResult.fromJson(Map<String, dynamic> json) =>
      RunModuleCommandResult(
        ok: json['ok'] as bool,
        output: json['output'] as String?,
        error: json['error'] as String?,
        messageId: json['message_id'] as String?,
      );
}
