// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A blocks controller that holds a fixed state and never fetches.
library;

import 'package:slimm_app/src/providers/blocks_controller.dart';

class FixedBlocksController extends BlocksController {
  FixedBlocksController(super.ref, BlocksState fixed) {
    state = fixed;
  }

  @override
  Future<void> refresh() async {}
}
