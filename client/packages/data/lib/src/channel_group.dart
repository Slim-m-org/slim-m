// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the local channel row knows about a group DM (decision 0095).
library;

import 'database.dart';

extension GroupDmChannel on Channel {
  /// Every participant of a group DM, the caller included; empty otherwise.
  List<String> get groupMemberIds {
    final joined = dmMemberIds;
    if (joined == null || joined.isEmpty) return const [];
    return joined.split(',');
  }

  bool get isGroupDm => dmMemberIds != null && dmMemberIds!.isNotEmpty;
}
