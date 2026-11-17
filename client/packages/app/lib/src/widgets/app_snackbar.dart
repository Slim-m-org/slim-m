// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one short message this app floats over the screen, for the call sites
/// that name themselves after the SnackBar they used to raise.
///
/// It goes through `toastsProvider`, so there is a single toast style:
/// outlined card, dismissible, stacked by [ToastOverlay], above every route.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/toasts.dart';

/// Shows [message] as a toast.
void showAppSnackbar(BuildContext context, String message) {
  ProviderScope.containerOf(
    context,
    listen: false,
  ).read(toastsProvider.notifier).show(message);
}
