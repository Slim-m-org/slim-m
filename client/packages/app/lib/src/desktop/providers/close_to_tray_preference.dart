// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether closing the desktop window keeps the app running in the tray, as
/// a user setting. On by default, like Discord; off makes the close button
/// quit, for people who read a window that will not close as a bug.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/preference_controller.dart';
import '../../providers/providers.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const closeToTrayKey = 'slimm.desktop.close_to_tray';

class CloseToTrayController extends Notifier<bool>
    implements RestorablePreference {
  @override
  bool build() {
    unawaited(restore());
    return true;
  }

  @override
  Future<void> restore() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      final stored = prefs.getBool(closeToTrayKey);
      if (stored != null) state = stored;
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'Could not read the close to tray setting; keeping it on',
        error,
        stack,
      );
    }
  }

  Future<void> set(bool on) async {
    state = on;
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setBool(closeToTrayKey, on);
  }
}

final closeToTrayProvider = NotifierProvider<CloseToTrayController, bool>(
  CloseToTrayController.new,
);
