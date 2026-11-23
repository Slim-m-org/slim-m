// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One pop-out window per feed, even when opening one runs Dart again: on
/// Windows the first stream pop-out opened two windows and leaked the hidden one.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/popout_window_set.dart';

class _Window {
  _Window(this.feed);

  final String feed;
  bool closed = false;
}

void main() {
  late List<_Window> opened;
  late PopOutWindowSet<String, _Window> set;
  void Function()? duringOpen;

  setUp(() {
    opened = [];
    duringOpen = null;
    set = PopOutWindowSet<String, _Window>(
      open: (feed) {
        final window = _Window(feed);
        opened.add(window);
        final reenter = duringOpen;
        duringOpen = null;
        reenter?.call();
        return window;
      },
      close: (window) => window.closed = true,
    );
  });

  test('a request made while the window is being created opens no second', () {
    duringOpen = () => set.sync({'screen': 'screen'});
    set.sync({'screen': 'screen'});

    expect(opened, hasLength(1));
    expect(set.windows.single, same(opened.single));
    expect(opened.single.closed, isFalse);
  });

  test('a request for another feed made meanwhile still opens it after', () {
    duringOpen = () => set.sync({'screen': 'screen', 'camera': 'camera'});
    set.sync({'screen': 'screen'});

    expect(opened.map((w) => w.feed), ['screen', 'camera']);
    expect(set.windows, hasLength(2));
  });

  test('a superseded window is destroyed', () {
    set.sync({'screen': 'screen'});
    final first = opened.single;
    final second = _Window('screen');

    set.adopt('screen', second);

    expect(first.closed, isTrue);
    expect(set.windows.single, same(second));
  });

  test('a feed no longer wanted closes its window', () {
    set.sync({'screen': 'screen', 'camera': 'camera'});
    set.sync({'camera': 'camera'});

    expect(opened.first.closed, isTrue);
    expect(set.windows.single.feed, 'camera');
  });

  test('closeAll destroys every window', () {
    set.sync({'screen': 'screen', 'camera': 'camera'});
    set.closeAll();

    expect(opened.every((w) => w.closed), isTrue);
    expect(set.isEmpty, isTrue);
  });
}
