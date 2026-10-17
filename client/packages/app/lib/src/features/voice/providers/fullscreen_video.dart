// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a full-screen video route is up, so the desktop chrome can step
/// aside and let the video cover the whole display.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

final fullscreenVideoActiveProvider = StateProvider<bool>((ref) => false);
