// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The camera a join asked for, opened after the call is already connected.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show LogTag, reportFailure;

import 'camera_switching.dart';

/// How long a join-time camera open may take before the person is told.
const kJoinCameraTimeout = Duration(seconds: 10);

/// The cause reported when the platform never answered a join-time camera open.
class CameraOpenTimedOut implements Exception {
  const CameraOpenTimedOut();

  @override
  String toString() => 'The camera did not respond in time.';
}

/// Where the join-time camera open stands: started, or settled with or without a [failure].
class CameraJoinOpen {
  const CameraJoinOpen.started()
      : pending = true,
        failure = null;

  const CameraJoinOpen.settled([this.failure]) : pending = false;

  final bool pending;
  final Object? failure;
}

/// Runs the deferred camera open of a join and reports it, so a slow webcam cannot hold "connected" back.
class CameraJoin {
  CameraJoin({this.timeout = kJoinCameraTimeout});

  final Duration timeout;
  final _events = StreamController<CameraJoinOpen>.broadcast();
  bool _opening = false;

  Stream<CameraJoinOpen> get events => _events.stream;

  /// Opens the camera through [enable], reporting the outcome only while [current] still holds.
  ///
  /// A timeout is reported as a failure, so a camera that opens after it is turned off again through [abandon]: the person was told it failed.
  Future<void> open({
    required Future<CameraToggleResult> Function() enable,
    required bool Function() current,
    void Function(Object error)? noteFailure,
    Future<void> Function()? abandon,
  }) async {
    _set(const CameraJoinOpen.started());
    final result = await _enableWithin(enable, abandon);
    if (!current()) return;
    final error = result.error;
    if (error != null) noteFailure?.call(error);
    _set(CameraJoinOpen.settled(error));
  }

  Future<CameraToggleResult> _enableWithin(
    Future<CameraToggleResult> Function() enable,
    Future<void> Function()? abandon,
  ) async {
    try {
      final pending = enable();
      return await pending.timeout(
        timeout,
        onTimeout: () {
          unawaited(_abandonLate(pending, abandon));
          return const CameraToggleResult.failed(CameraOpenTimedOut(), null);
        },
      );
    } catch (error, stack) {
      reportFailure(
          LogTag.voice, 'open the camera after joining', error, stack);
      return CameraToggleResult.failed(error, null);
    }
  }

  Future<void> _abandonLate(
    Future<CameraToggleResult> pending,
    Future<void> Function()? abandon,
  ) async {
    try {
      if ((await pending).ok) await abandon?.call();
    } catch (error, stack) {
      reportFailure(LogTag.voice, 'close a late camera', error, stack);
    }
  }

  /// Ends a pending open that a leave or a newer join overtook, without a failure.
  void cancel() {
    if (_opening) _set(const CameraJoinOpen.settled());
  }

  Future<void> dispose() => _events.close();

  void _set(CameraJoinOpen next) {
    _opening = next.pending;
    if (!_events.isClosed) _events.add(next);
  }
}
