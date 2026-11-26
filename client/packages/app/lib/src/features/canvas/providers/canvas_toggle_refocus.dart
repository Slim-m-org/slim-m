// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where keyboard focus goes when the canvas closes from the call dock.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Set when the canvas was closed from the keyboard, so the control that takes the Close slot's place picks up focus instead of focus falling to the top.
final canvasToggleRefocusProvider = StateProvider<bool>((ref) => false);
