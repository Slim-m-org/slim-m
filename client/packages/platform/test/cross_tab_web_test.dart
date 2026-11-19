// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A browser tab's id, which every voice join and roster read carries so the
/// server can tell this tab's call from another tab's of the same session.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';
import 'package:web/web.dart' as web;

const _key = 'slimm.tab_id';

/// Makes `window.sessionStorage` throw, as a storage-blocked or sandboxed page does; answers the undo.
void Function() _blockSessionStorage() {
  final object = globalContext['Object']! as JSObject;
  final name = 'sessionStorage'.toJS;
  final original = object.callMethod<JSAny?>(
    'getOwnPropertyDescriptor'.toJS,
    web.window,
    name,
  );
  JSAny? blocked() => throw StateError('session storage is blocked');
  final throwing = JSObject()
    ..['configurable'] = true.toJS
    ..['get'] = blocked.toJS;
  object.callMethod<JSAny?>('defineProperty'.toJS, web.window, name, throwing);
  return () => object.callMethod<JSAny?>(
        'defineProperty'.toJS,
        web.window,
        name,
        original,
      );
}

void main() {
  tearDown(() => web.window.sessionStorage.removeItem(_key));

  test('a reload keeps the id its tab left in session storage', () async {
    web.window.sessionStorage.setItem(_key, 'ab12');
    expect(await CrossTab().tabId, 'ab12');
  });

  test(
      'a duplicated tab, holding a copy of the session storage, takes an '
      'id of its own', () async {
    web.window.sessionStorage.setItem(_key, 'cd34');
    final original = await CrossTab().tabId;
    final duplicate = await CrossTab().tabId;
    expect(original, 'cd34');
    expect(duplicate, isNot(original));
    expect(web.window.sessionStorage.getItem(_key), duplicate);
  });

  test('a stored id the server would refuse is replaced', () async {
    web.window.sessionStorage.setItem(_key, 'Not Hex');
    final id = await CrossTab().tabId;
    expect(id, matches(RegExp(r'^[0-9a-f]{1,64}$')));
    expect(web.window.sessionStorage.getItem(_key), id);
  });

  test('a tab whose session storage is blocked sends no id at all', () async {
    addTearDown(_blockSessionStorage());
    expect(
      await CrossTab().tabId,
      isNull,
      reason: 'a fresh id on every load would make a reload its own stranger',
    );
  });
}
