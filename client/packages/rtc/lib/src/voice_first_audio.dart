// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Waits for the first packet of remote audio, for the join timing marks.
library;

import 'package:slimm_api/api.dart' show AppLog, LogTag;

const _pollEvery = Duration(milliseconds: 50);
const _maxPolls = 100;

/// Polls [packetsReceived] until audio arrives, then calls [onAudio]; stops once [joinOpen] says the join is over, so a later subscription never polls.
Future<void> watchFirstAudio({
  required bool Function() joinOpen,
  required Future<num?> Function() packetsReceived,
  required void Function() onAudio,
  Duration every = _pollEvery,
}) async {
  for (var i = 0; i < _maxPolls && joinOpen(); i++) {
    try {
      if ((await packetsReceived() ?? 0) > 0) {
        onAudio();
        return;
      }
    } on Object catch (error, stack) {
      // Stats can fail while a track is torn down; the loop's bounds end the wait.
      AppLog.swallowed(
          LogTag.voice, 'Could not read receiver stats', error, stack);
    }
    await Future<void>.delayed(every);
  }
}
