// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the admin setup is showing, and what finishing or skipping it saves.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../permissions.dart';
import '../../../providers/providers.dart';
import '../../first_run/providers/first_run_controller.dart';

/// The server's report on this machine and the setup state, `GET /space/setup`.
final spaceSetupProvider = FutureProvider.autoDispose<api.SpaceSetup>(
  (ref) => ref.watch(apiProvider).spaceSetup(),
);

typedef AdminSetupState = ({bool active, bool replay});

const _idle = (active: false, replay: false);

class AdminSetupController extends StateNotifier<AdminSetupState> {
  AdminSetupController(this._ref) : super(_idle) {
    unawaited(_check());
  }

  final Ref _ref;

  /// Asked only of an admin, so a member never makes the call; the server
  /// answers `owed` for the claiming admin alone, until they finish it.
  Future<void> _check() async {
    try {
      final me = await _ref.read(meProvider.future);
      if (!me.permissions.hasPermission(Perm.manageServer)) return;
      await _ref.read(firstRunControllerProvider.notifier).ready;
      final setup = await _ref.read(spaceSetupProvider.future);
      if (mounted && setup.owed) state = (active: true, replay: false);
    } catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.ui,
        'Could not check whether to offer the admin setup; skipping it',
        error,
        stack,
      );
    }
  }

  /// Opens the setup again from Settings; finishing it saves nothing.
  void replay() => state = (active: true, replay: true);

  /// Closes the flow. The first time it also tells the server, so the offer
  /// never returns on any device; a failure leaves the flow open and throws.
  Future<void> complete() async {
    if (!state.replay) {
      await _ref.read(apiProvider).completeSpaceSetup();
      _ref.invalidate(spaceSetupProvider);
    }
    if (mounted) state = _idle;
  }
}

final adminSetupControllerProvider =
    StateNotifierProvider<AdminSetupController, AdminSetupState>(
      (ref) => AdminSetupController(ref),
    );
