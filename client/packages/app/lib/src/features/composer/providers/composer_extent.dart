// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How tall the main pane's bottom stack (banners and composer) is right now,
/// so a floating card can rest above it however far a long draft has grown it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Measured by `DockHeightReporter` around the channel composer area; 0 when none is mounted.
final composerExtentProvider = StateProvider<double>((ref) => 0);
