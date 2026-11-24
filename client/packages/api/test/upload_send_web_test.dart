// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser upload is aborted when its caller gives up, not left running.
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:slimm_api/src/upload_send_web.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

/// Stands in for an XMLHttpRequest that never answers, and records abort().
class _FakeXhr {
  final calls = <String>[];

  late final JSObject object = _build();

  JSObject _build() {
    final upload = JSObject();
    final xhr = JSObject()..setProperty('upload'.toJS, upload);
    void method(String name, [void Function()? then]) {
      xhr.setProperty(
        name.toJS,
        ([JSAny? a, JSAny? b]) {
          calls.add(name);
          then?.call();
        }.toJS,
      );
    }

    method('open');
    method('setRequestHeader');
    method('send');
    method('abort', () {
      final onabort = xhr.getProperty<JSFunction?>('onabort'.toJS);
      onabort?.callAsFunction(xhr, JSObject());
    });
    return xhr;
  }

  web.XMLHttpRequest asXhr() => object as web.XMLHttpRequest;
}

void main() {
  http.StreamedRequest request() =>
      http.StreamedRequest('PUT', Uri.parse('http://localhost/x'));

  test('aborts the request when the trigger fires, and fails the send',
      () async {
    final xhr = _FakeXhr();
    final trigger = Completer<void>();
    final sent = sendXhrUpload(
      request(),
      Uint8List.fromList([1, 2, 3]),
      (_) {},
      abortTrigger: trigger.future,
      createXhr: xhr.asXhr,
    );
    expect(xhr.calls, contains('send'));
    expect(xhr.calls, isNot(contains('abort')));

    trigger.complete();
    await expectLater(sent, throwsA(isA<http.ClientException>()));
    expect(xhr.calls, contains('abort'));
  });
}
