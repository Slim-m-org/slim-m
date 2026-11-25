// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The draw tool picked on a sharer's screen, so the stage and its full screen view agree on it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ScreenAnnotateTool { pen, ellipse, note, stamp }

final screenAnnotateToolProvider = StateProvider.autoDispose
    .family<ScreenAnnotateTool?, String>((ref, sharerId) => null);
