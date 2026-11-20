// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps a longer debug log while this account's space has server debug
/// logging on, so a log sent after a long call still reaches its start.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show ServerLogMode;

import '../providers/server_info.dart';
import 'debug_log.dart';

final debugLogDetailProvider = Provider<void>((ref) {
  final log = ref.watch(debugLogProvider.notifier);
  final source = Object();
  ref.listen(serverInfoProvider, (_, next) {
    final mode = next.valueOrNull?.debugLogging;
    if (mode != null) log.keepDetail(source, on: mode != ServerLogMode.off);
  }, fireImmediately: true);
  ref.onDispose(() => log.keepDetail(source, on: false));
});
