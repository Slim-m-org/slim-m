// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a ring's caller is blocked, and dropping a ring whose caller becomes blocked.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../members/providers/blocks_controller.dart';

class DmCallRingBlocks {
  DmCallRingBlocks(
    this._ref, {
    required this.incomingCaller,
    required this.dropIncoming,
  });

  final Ref _ref;
  final String? Function() incomingCaller;
  final void Function() dropIncoming;
  bool _watching = false;

  /// Read once the signed-in shell has loaded the list; a block drops the ring at once.
  bool isBlocked(String userId) {
    if (!_ref.exists(blocksProvider)) return false;
    if (!_watching) {
      _watching = true;
      _ref.listen<BlocksState>(blocksProvider, (_, next) {
        if (next.contains(incomingCaller())) dropIncoming();
      });
    }
    return _ref.read(blocksProvider).contains(userId);
  }
}
