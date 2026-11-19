// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which channel's canvas is open, as a mode of the channel rather than a route.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The channel whose canvas is open, or null.
///
/// A provider rather than a route: joining a call opens voice and the canvas
/// as one screen (STRATEGY), and a separate navigation step is the alternative
/// that was rejected. The cost is stated rather than discovered: no URL, no
/// deep link, and no browser back to close it.
final canvasOpenProvider = StateProvider<String?>((ref) => null);
