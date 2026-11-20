// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What an action from an already-closed surface (a context menu, a member card)
/// says once its request answers.
///
/// Nothing is left on screen to hold an `AppErrorState`, so a failure becomes an
/// error toast that stays until dismissed, and a success a confirmation that
/// times out (decision 0018).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/toasts.dart';

/// Shows [failure] as an error toast that stays until dismissed.
void showMenuFailure(BuildContext context, String failure) => _toasts(
  context,
).show(failure, severity: AppToastSeverity.error, duration: Duration.zero);

/// Shows [failure] when there is one, otherwise confirms with [succeeded].
void showMenuOutcome(
  BuildContext context, {
  required String? failure,
  required String succeeded,
}) {
  if (failure != null) {
    showMenuFailure(context, failure);
  } else {
    _toasts(context).show(succeeded, severity: AppToastSeverity.success);
  }
}

ToastsController _toasts(BuildContext context) => ProviderScope.containerOf(
  context,
  listen: false,
).read(toastsProvider.notifier);
