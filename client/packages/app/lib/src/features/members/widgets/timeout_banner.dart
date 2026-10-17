// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The strip above the composer while the caller is timed out: when it
/// lifts, and why, if the moderator left a reason.
///
/// Before this existed, a timed-out member's blocked send surfaced as a bare
/// refusal - `MeDto.timedOutUntil` disabled nothing on its own, and
/// `MeDto.timeoutReason` (see MOD6) had nowhere to show up at all. This is a
/// pure display widget: whether to show it at all is `ChannelComposerArea`'s
/// call, the same split `ReplyBanner` already draws with `replyingTo`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../format.dart';
import '../../settings/providers/display_preferences.dart';

class TimeoutBanner extends ConsumerWidget {
  const TimeoutBanner({super.key, required this.until, this.reason});

  /// Unix milliseconds the timeout lifts at. The caller only builds this
  /// widget once it has checked this is still in the future.
  final int until;

  /// Why the moderator timed them out, or null if none was given.
  final String? reason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final when = formatDateTime(until, use24Hour: watchUse24Hour(ref, context));
    return AppCallout(
      tone: AppCalloutTone.warn,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('You are timed out until $when.'),
          if (reason != null) Text('Reason: $reason'),
        ],
      ),
    );
  }
}
