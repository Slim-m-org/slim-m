// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Running a write that can fail, and saying so if it does.
///
/// Twenty-six places wrote the same six lines: set busy, await the call,
/// invalidate a provider, catch `ApiException`, clear busy, show a
/// `SnackBar`. Two things were wrong with that beyond the repetition. The
/// message interpolated the exception, so a transport failure put
/// `POST /invites failed: SocketException...` in front of a user. And a
/// `SnackBar` is the wrong shape for a failure at all under the error
/// grammar: it floats away from the control and leaves no record.
///
/// This keeps the control flow in one place and hands the failure back as a
/// plain sentence for the caller to render where the action was - with
/// [AppErrorState] for a surface that has room, or an inline caption where
/// it does not.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' as api;

import '../api_failure.dart';

/// Runs [action], returning null on success or a human sentence on failure.
///
/// [whatFailed] names the action from the user's side ("revoke the invite"),
/// and the returned sentence reads "Could not revoke the invite." See
/// [describeApiFailure] for what each kind of failure says and why.
Future<String?> runGuarded({
  required String whatFailed,
  required Future<void> Function() action,
}) async {
  try {
    await action();
    return null;
  } on api.ApiException catch (e, s) {
    return reportFailureSentence(api.LogTag.ui, whatFailed, e, s);
  }
}

/// The shape of [GuardedActionState.guard], for a helper that needs to run a
/// request but has no state of its own to hold the failure in - the caller's
/// mixin is what ends up rendering it.
typedef Guard =
    Future<bool> Function({
      required String whatFailed,
      required Future<void> Function() action,
    });

/// Holds the last failure from [runGuarded] for a widget that renders it.
///
/// A mixin rather than a base class so it composes with the `ConsumerState`
/// these screens already extend.
mixin GuardedActionState<T extends StatefulWidget> on State<T> {
  String? _actionError;
  int _successTick = 0;

  /// The last failure, or null. Render it where the action is.
  String? get actionError => _actionError;

  /// Bumps on every [guard] success. Feed it to a `SuccessFlash` so a write
  /// that worked is visibly acknowledged rather than silently done - failure
  /// always had a shape here ([actionError]) and success had none.
  int get successTick => _successTick;

  /// Clears it, for a dismiss control.
  void clearActionError() {
    if (_actionError != null) setState(() => _actionError = null);
  }

  /// Sets the failure directly, for one [guard] cannot cover because it
  /// never carries an [api.ApiException] - a native file picker throwing,
  /// say, which is not a request [runGuarded] could have wrapped.
  void setActionError(String message) {
    if (mounted) setState(() => _actionError = message);
  }

  /// [runGuarded], with the result stored and a `mounted` check after the
  /// await - the guard every one of the twenty-six copies had to remember.
  Future<bool> guard({
    required String whatFailed,
    required Future<void> Function() action,
  }) async {
    final failure = await runGuarded(whatFailed: whatFailed, action: action);
    if (!mounted) return failure == null;
    setState(() {
      _actionError = failure;
      if (failure == null) _successTick++;
    });
    return failure == null;
  }
}
