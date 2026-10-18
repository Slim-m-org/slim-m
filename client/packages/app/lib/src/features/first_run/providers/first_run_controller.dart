// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether first-run setup is showing, and what finishing or skipping it saves.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart' show Channel, hasMessageFrom;

import '../../../providers/providers.dart';
import 'first_run_rules.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// Who invited this account, when the invite they signed up with said so.
final firstRunInviterProvider = StateProvider<String?>((ref) => null);

/// Injectable so a test can put an account on either side of the one-day window.
final firstRunClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// [offered] is whether setup is still owed on this device, for the home to offer it.
typedef FirstRunState = ({
  bool active,
  bool replay,
  bool voiceHint,
  bool offered,
});

const _idle = (active: false, replay: false, voiceHint: false, offered: false);

class FirstRunController extends StateNotifier<FirstRunState> {
  FirstRunController(this._ref) : super(_idle) {
    unawaited(_check());
  }

  final Ref _ref;
  String? _space;
  String? _account;

  Future<void> _check() async {
    try {
      final me = await _ref.read(meProvider.future);
      final prefs = await _ref.read(preferencesProvider.future);
      final store = await _ref.read(storeProvider.future);
      final space = _space = '${_ref.read(chosenServerProvider)}';
      final account = _account = me.id;
      final done = prefs.getBool(firstRunDoneKey(space, account)) ?? false;
      final wrote = await hasMessageFrom(store, account);
      final due = firstRunDue(
        done: done,
        accountCreatedAtMs: me.createdAt,
        hasOwnMessages: wrote,
        now: _ref.read(firstRunClockProvider)(),
      );
      if (!mounted) return;
      final hint = prefs.getBool(firstRunVoiceHintKey(space, account)) ?? false;
      state = (
        active: due,
        replay: false,
        voiceHint: hint && !due,
        offered: !done && !wrote,
      );
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Could not check whether to show the welcome screen; skipping it',
        error,
        stack,
      );
    }
  }

  /// Opens setup for the first time, so finishing or skipping it is remembered.
  void start() => state = (
    active: true,
    replay: false,
    voiceHint: false,
    offered: state.offered,
  );

  /// Opens setup again from Settings, whatever was saved.
  void replay() => state = (
    active: true,
    replay: true,
    voiceHint: false,
    offered: state.offered,
  );

  /// Closes the flow for good. [voiceHint] arms the hint; a replay writes nothing.
  Future<void> complete({bool voiceHint = false}) async {
    final replay = state.replay;
    final hint = voiceHint && !replay;
    state = (
      active: false,
      replay: false,
      voiceHint: hint,
      offered: replay && state.offered,
    );
    if (replay) return;
    final space = _space;
    final account = _account;
    if (space == null || account == null) return;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(firstRunDoneKey(space, account), true);
    if (hint) await prefs.setBool(firstRunVoiceHintKey(space, account), true);
  }

  Future<void> dismissVoiceHint() async {
    state = (
      active: state.active,
      replay: state.replay,
      voiceHint: false,
      offered: state.offered,
    );
    final space = _space;
    final account = _account;
    if (space == null || account == null) return;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.remove(firstRunVoiceHintKey(space, account));
  }

  /// The channels, read at the moment a landing is chosen.
  Future<List<Channel>> channels() async =>
      (await _ref.read(storeProvider.future)).allChannels();
}

final firstRunControllerProvider =
    StateNotifierProvider<FirstRunController, FirstRunState>(
      (ref) => FirstRunController(ref),
    );
