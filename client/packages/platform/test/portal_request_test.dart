// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A portal request must not leave its Response subscription behind, however it ends.
library;

import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/src/portal_request.dart';

DBusSignal _response(int code, Map<String, DBusValue> results) => DBusSignal(
      sender: ':1.5',
      path: DBusObjectPath('/org/freedesktop/portal/desktop/request/1_42/t'),
      interface: portalRequestInterface,
      name: 'Response',
      values: [DBusUint32(code), DBusDict.stringVariant(results)],
    );

void main() {
  late StreamController<DBusSignal> responses;

  setUp(() => responses = StreamController<DBusSignal>.broadcast());
  tearDown(() => responses.close());

  test('the code and results come back from the Response', () async {
    final answered = await awaitPortalResponse(
      responses: responses.stream,
      call: () async =>
          responses.add(_response(0, {'autostart': DBusBoolean(true)})),
    );
    expect(answered.code, 0);
    expect(answered.results['autostart'], DBusBoolean(true));
    expect(responses.hasListener, isFalse);
  });

  test('an answer that lands during the call is not missed', () async {
    final answered = await awaitPortalResponse(
      responses: responses.stream,
      call: () async {
        responses.add(_response(1, {}));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      },
    );
    expect(answered.code, 1);
  });

  test('a request nobody answers lets go of its subscription', () async {
    final waiting = awaitPortalResponse(
      responses: responses.stream,
      call: () async {},
      timeout: const Duration(milliseconds: 20),
    );
    expect(responses.hasListener, isTrue);
    await expectLater(waiting, throwsA(isA<TimeoutException>()));
    expect(responses.hasListener, isFalse);
  });

  test('a call that throws lets go of its subscription', () async {
    await expectLater(
      awaitPortalResponse(
        responses: responses.stream,
        call: () async => throw StateError('portal gone'),
      ),
      throwsStateError,
    );
    expect(responses.hasListener, isFalse);
  });

  test('a failing cancel does not hide the original error', () async {
    await expectLater(
      awaitPortalResponse(
        responses: _FailingCancel(),
        call: () async => throw ArgumentError('portal gone'),
      ),
      throwsArgumentError,
    );
  });
}

class _FailingCancel extends Stream<DBusSignal> {
  @override
  StreamSubscription<DBusSignal> listen(
    void Function(DBusSignal event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _FailingCancelSubscription();
}

class _FailingCancelSubscription implements StreamSubscription<DBusSignal> {
  @override
  Future<void> cancel() => Future.error(StateError('match rule already gone'));

  @override
  void onData(void Function(DBusSignal data)? handleData) {}

  @override
  void onError(Function? handleError) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void pause([Future<void>? resumeSignal]) {}

  @override
  void resume() {}

  @override
  bool get isPaused => false;

  @override
  Future<E> asFuture<E>([E? futureValue]) => Completer<E>().future;
}
