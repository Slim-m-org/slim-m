// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'tab_channel.dart';

TabChannel createTabChannel(String name) => _BrowserChannel(name);

class _BrowserChannel implements TabChannel {
  _BrowserChannel(String name) : _channel = web.BroadcastChannel(name);

  final web.BroadcastChannel _channel;

  @override
  late final Stream<String> messages = web.EventStreamProviders.messageEvent
      .forTarget(_channel)
      .map((event) => event.data)
      .where((data) => data.isA<JSString>())
      .map((data) => (data as JSString).toDart)
      .asBroadcastStream();

  @override
  void post(String message) => _channel.postMessage(message.toJS);
}
