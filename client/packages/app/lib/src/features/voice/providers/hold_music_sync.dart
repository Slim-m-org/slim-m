// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the hold-music toggle the same on every device of an account.
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/app_lifecycle.dart';
import '../../../providers/providers.dart';
import 'voice_settings_controller.dart';

/// The account's value wins, unless this device holds a toggle the account never
/// received; with no account value yet, this device's own choice is uploaded.
Future<void> syncHoldMusic(
  T Function<T>(ProviderListenable<T> provider) read,
) async {
  try {
    final prefs = await read(preferencesProvider.future);
    final local = prefs.getBool(holdMusicEnabledKey);
    if (local != null && (prefs.getBool(holdMusicUnsentKey) ?? false)) {
      await read(apiProvider).setHoldMusic(local);
      await prefs.remove(holdMusicUnsentKey);
      return;
    }
    final served = await read(apiProvider).holdMusic();
    final controller = read(voiceSettingsControllerProvider.notifier);
    if (served != null) {
      await controller.applyHoldMusicEnabled(served);
      return;
    }
    if (local != null) await read(apiProvider).setHoldMusic(local);
  } catch (error, stack) {
    reportFailure(
      LogTag.voice,
      'sync hold music with the account',
      error,
      stack,
    );
  }
}

/// Syncs when the account's services start and whenever the app comes back.
final holdMusicSyncProvider = Provider<void>((ref) {
  var disposed = false;
  ref.onDispose(() => disposed = true);
  void run() {
    if (!disposed) unawaited(syncHoldMusic(ref.read));
  }

  ref.listen(appLifecycleProvider, (_, state) {
    if (state == AppLifecycleState.resumed) run();
  });
  run();
});
