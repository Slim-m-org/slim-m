// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Dock panels (decision 0132): which panels this viewer may open, which one
/// is docked open, and the latest scene of each, kept here rather than in the
/// pane so a panel shows the same scene after a channel switch, a resize or a
/// thread taking its slot for a while.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../api_failure.dart';
import '../../../providers/providers.dart';

/// Every panel this viewer may open: `GET /modules/panels`, empty on an older server.
final modulePanelsProvider = FutureProvider.autoDispose<List<api.ModulePanel>>(
  (ref) => ref.watch(apiProvider).listModulePanels(),
);

/// The panel docked beside the conversation on a wide window, or null.
final openModulePanelProvider = StateProvider<api.ModulePanel?>((ref) => null);

/// How often a panel may ask to be redrawn, the same bounds the host keeps for a shared scene.
const panelRefreshMin = Duration(seconds: 2);
const panelRefreshMax = Duration(seconds: 60);

/// A redraw chain ends this long after the viewer last pressed something.
const panelRefreshWindow = Duration(minutes: 30);

/// One panel's scene: its first run in flight, refused, or its latest answer.
class ModulePanelRun {
  const ModulePanelRun.running()
    : result = null,
      error = null,
      lastPressAt = null;
  const ModulePanelRun.refused(this.error) : result = null, lastPressAt = null;
  const ModulePanelRun.answered(this.result, {this.lastPressAt}) : error = null;

  final api.RunModuleCommandResult? result;
  final String? error;

  /// When the viewer last acted on it, which keeps a redraw chain going.
  final DateTime? lastPressAt;

  bool get running => result == null && error == null;

  /// The redraw interval the scene asks for, clamped, or null when it asks for none.
  Duration? get refreshEvery {
    final output = result?.output;
    if (result?.ok != true ||
        output == null ||
        !output.contains('refresh_ms')) {
      return null;
    }
    final asked = _scene(output)?['refresh_ms'];
    if (asked is! num) return null;
    final ms = asked.toInt().clamp(
      panelRefreshMin.inMilliseconds,
      panelRefreshMax.inMilliseconds,
    );
    return Duration(milliseconds: ms);
  }

  /// The opaque state the scene holds, handed back with a redraw.
  String? get heldState => switch (_scene(result?.output ?? '')?['state']) {
    final String state => state,
    _ => null,
  };

  static Map<String, Object?>? _scene(String output) {
    try {
      final decoded = jsonDecode(output);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}

class ModulePanelRuns extends Notifier<Map<String, ModulePanelRun>> {
  final _inFlight = <String, int>{};

  @override
  Map<String, ModulePanelRun> build() => const {};

  /// Runs [panel]'s first frame unless it already has one; [retry] replaces a refusal.
  Future<void> open(api.ModulePanel panel, {bool retry = false}) async {
    final current = state[panel.key];
    if (current != null && (current.running || !retry)) return;
    _put(panel.key, const ModulePanelRun.running());
    try {
      final result = await _call(panel, '');
      _put(
        panel.key,
        result.ok
            ? ModulePanelRun.answered(result)
            : ModulePanelRun.refused(result.error ?? 'This panel failed.'),
      );
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'open a panel', e, stack);
      _put(
        panel.key,
        ModulePanelRun.refused(describeApiFailure('open ${panel.name}', e)),
      );
    } catch (error, stack) {
      api.reportFailure(api.LogTag.ui, 'open a panel', error, stack);
      _put(
        panel.key,
        ModulePanelRun.refused('Could not open ${panel.name}. Try again.'),
      );
    }
  }

  /// One action from the panel's scene; a good answer becomes the panel's scene.
  Future<api.RunModuleCommandResult> act(
    api.ModulePanel panel,
    String input,
  ) async {
    final result = await _call(panel, input);
    if (result.ok) {
      _put(
        panel.key,
        ModulePanelRun.answered(result, lastPressAt: DateTime.now()),
      );
    }
    return result;
  }

  /// Redraws [panel] with the action `refresh` when its scene still asks and nothing else is running.
  Future<void> refresh(api.ModulePanel panel) async {
    final current = state[panel.key];
    if (current?.refreshEvery == null || (_inFlight[panel.key] ?? 0) > 0) {
      return;
    }
    final pressed = current!.lastPressAt;
    if (pressed != null &&
        DateTime.now().difference(pressed) > panelRefreshWindow) {
      return;
    }
    try {
      final result = await _call(
        panel,
        jsonEncode({'action': 'refresh', 'state': current.heldState ?? ''}),
      );
      if (result.ok && identical(state[panel.key], current)) {
        _put(panel.key, ModulePanelRun.answered(result, lastPressAt: pressed));
      }
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'redraw a panel', e, stack);
    }
  }

  Future<api.RunModuleCommandResult> _call(
    api.ModulePanel panel,
    String input,
  ) async {
    _inFlight.update(panel.key, (n) => n + 1, ifAbsent: () => 1);
    try {
      return await ref
          .read(apiProvider)
          .runModuleCommand(
            moduleId: panel.moduleId,
            command: panel.command,
            input: input,
          );
    } finally {
      _inFlight.update(panel.key, (n) => n - 1);
    }
  }

  void _put(String key, ModulePanelRun run) => state = {...state, key: run};
}

final modulePanelRunsProvider =
    NotifierProvider<ModulePanelRuns, Map<String, ModulePanelRun>>(
      ModulePanelRuns.new,
    );
