// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ctrl+1 to Ctrl+9 (Cmd on Apple) jump to the nth signed-in server.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../providers/account_providers.dart';

/// Empty with no account host, and on web, where the browser keeps these keys.
Map<ShortcutActivator, VoidCallback> serverSwitchBindings(WidgetRef ref) {
  final host = ref.read(accountHostProvider);
  if (host == null) return const {};
  final activators = serverSwitchActivators();
  return {
    for (var i = 0; i < activators.length; i++)
      activators[i]: () {
        final entries = ref.read(accountsSnapshotProvider).entries;
        if (i < entries.length) {
          unawaited(host.switchTo(entries[i].account.origin));
        }
      },
  };
}
