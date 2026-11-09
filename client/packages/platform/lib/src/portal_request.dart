// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The request and response round trip every xdg-desktop-portal method that can ask the person something shares.
library;

import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:slimm_api/api.dart' show LogTag, ignoreError;

const portalBusName = 'org.freedesktop.portal.Desktop';
const portalPath = '/org/freedesktop/portal/desktop';
const portalRequestInterface = 'org.freedesktop.portal.Request';

/// How long a portal may wait on the person before the request is given up.
const portalApprovalTimeout = Duration(minutes: 2);

/// A portal's `Response`: [code] 0 is success, 1 the person cancelled, 2 anything else.
typedef PortalResponse = ({int code, Map<String, DBusValue> results});

/// Where the portal answers a request made by [uniqueName] with [token].
String portalRequestPath(String uniqueName, String token) {
  final sender = uniqueName.replaceFirst(':', '').replaceAll('.', '_');
  return '/org/freedesktop/portal/desktop/request/$sender/$token';
}

/// The `Response` signals for the request at [path].
Stream<DBusSignal> portalResponses(DBusClient bus, DBusObjectPath path) =>
    DBusSignalStream(
      bus,
      sender: portalBusName,
      interface: portalRequestInterface,
      name: 'Response',
      path: path,
    );

/// Runs [call] and waits for the portal's answer on [responses].
///
/// It listens first so a fast answer is not missed, and lets go of the
/// subscription however this ends, so an abandoned request keeps no match rule.
Future<PortalResponse> awaitPortalResponse({
  required Stream<DBusSignal> responses,
  required Future<void> Function() call,
  Duration timeout = portalApprovalTimeout,
}) async {
  final answer = Completer<DBusSignal>();
  // An error that lands after a failed call has no one left to read it.
  answer.future.ignore();
  final subscription = responses.listen(
    (signal) {
      if (!answer.isCompleted) answer.complete(signal);
    },
    onError: (Object error, StackTrace stack) {
      if (!answer.isCompleted) answer.completeError(error, stack);
    },
  );
  try {
    await call();
    final signal = await answer.future.timeout(timeout);
    return (
      code: signal.values[0].asUint32(),
      results: signal.values[1].asStringVariantDict(),
    );
  } finally {
    await subscription.cancel().catchError(
          ignoreError(LogTag.platform, 'The portal response was already gone'),
        );
  }
}
