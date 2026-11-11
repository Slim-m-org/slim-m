// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sending the debug log to the admins: what is sent, and the call that sends it.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../api_failure.dart';
import '../../../diagnostics/debug_log.dart';
import '../../../diagnostics/debug_log_submission.dart';
import '../../../providers/providers.dart';

/// The most a note may say; the server refuses more.
const int debugLogNoteMaxChars = 500;

/// What a submission carries besides the note.
@immutable
class DebugLogContents {
  const DebugLogContents({
    required this.entries,
    required this.appVersion,
    required this.platform,
  });

  final int entries;
  final String appVersion;
  final String platform;
}

/// The platform name the admins read: the web build, or the operating system.
String debugLogPlatform() => kIsWeb ? 'web' : defaultTargetPlatform.name;

final debugLogContentsProvider = FutureProvider.autoDispose<DebugLogContents>((
  ref,
) async {
  final entries = ref.watch(debugLogProvider).length;
  final info = await ref.watch(appInfoProvider.future);
  return DebugLogContents(
    entries: entries,
    appVersion: '${info.version}+${info.buildNumber}',
    platform: debugLogPlatform(),
  );
});

class DebugLogSender {
  DebugLogSender(this._ref);

  final Ref _ref;

  /// Sends the scrubbed log with [note]; null on success, else the sentence to show.
  Future<String?> send(DebugLogContents contents, String note) async {
    final report = _ref.read(debugLogProvider.notifier).asReport();
    try {
      await _ref
          .read(apiProvider)
          .submitDebugLog(
            log: debugLogSubmission(report),
            note: note.trim(),
            appVersion: contents.appVersion,
            platform: contents.platform,
          );
      return null;
    } on Object catch (e, stack) {
      return reportFailureSentence(
        api.LogTag.ui,
        'send the debug log',
        e,
        stack,
      );
    }
  }
}

final debugLogSenderProvider = Provider<DebugLogSender>(DebugLogSender.new);
