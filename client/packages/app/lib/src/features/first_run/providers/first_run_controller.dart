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

typedef FirstRunState = ({bool active, bool replay, bool voiceHint});

const _idle = (active: false, replay: false, voiceHint: false);

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
      final due = firstRunDue(
        done: prefs.getBool(firstRunDoneKey(space, account)) ?? false,
        accountCreatedAtMs: me.createdAt,
        hasOwnMessages: await hasMessageFrom(store, account),
        now: _ref.read(firstRunClockProvider)(),
      );
      if (!mounted) return;
      final hint = prefs.getBool(firstRunVoiceHintKey(space, account)) ?? false;
      state = (active: due, replay: false, voiceHint: hint && !due);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Never the reason the shell fails to open; a missed welcome costs little',
        error,
        stack,
      );
    }
  }

  /// Opens setup again from Settings or the empty pane, whatever was saved.
  void replay() => state = (active: true, replay: true, voiceHint: false);

  /// Closes the flow for good. [voiceHint] arms the hint; a replay writes nothing.
  Future<void> complete({bool voiceHint = false}) async {
    final replay = state.replay;
    final hint = voiceHint && !replay;
    state = (active: false, replay: false, voiceHint: hint);
    if (replay) return;
    final space = _space;
    final account = _account;
    if (space == null || account == null) return;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(firstRunDoneKey(space, account), true);
    if (hint) await prefs.setBool(firstRunVoiceHintKey(space, account), true);
  }

  Future<void> dismissVoiceHint() async {
    state = (active: state.active, replay: state.replay, voiceHint: false);
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
