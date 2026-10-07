// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The last refused moderation write (or card note save), held for `ModerationErrorHost` to show.
///
/// Row menus and the profile popover close before their request answers, so
/// they have no place of their own for a failure. The app-level host outlives
/// them and, unlike the member pane, is mounted on every screen at every width.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Null when nothing is wrong; cleared by the host's dismiss control and at
/// the start of the next moderation write.
final memberModerationErrorProvider = StateProvider<String?>((ref) => null);
