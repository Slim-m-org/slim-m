// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one composer on screen registers its own focus node here, so the
/// global focus-composer shortcut has something to reach: `HomeShell` binds
/// the shortcut and is an ancestor of `Composer`, but it holds no reference
/// to `Composer`'s `FocusNode` - nothing passes one down the tree.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The mounted `Composer`'s own focus node, or null while none is on screen
/// (no channel selected, or a voice channel with no text composer at all).
final composerFocusNodeProvider = StateProvider<FocusNode?>((ref) => null);
