// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a desktop notification shows the message itself or only who sent
/// it. Per device and on by default: the desktop shows its own notifications
/// from messages it already has, unlike a phone's push, which is governed by
/// the account-wide lock screen setting instead.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';

const desktopMessageTextKey = 'slimm.notifications.desktop_message_text';

class DesktopMessageTextController extends StateNotifier<bool> {
  DesktopMessageTextController(this._ref) : super(true) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    final prefs = await _ref.read(preferencesProvider.future);
    state = prefs.getBool(desktopMessageTextKey) ?? true;
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(desktopMessageTextKey, enabled);
  }
}

final desktopMessageTextProvider =
    StateNotifierProvider<DesktopMessageTextController, bool>(
      DesktopMessageTextController.new,
    );
