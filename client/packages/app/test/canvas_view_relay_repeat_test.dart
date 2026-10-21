// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:ui';

import 'package:slimm_app/src/features/canvas/screens/canvas_view_relay.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'the repeat does not resend a stale view once nobody can receive it',
    () {
      fakeAsync((async) {
        var audience = true;
        final sent = <Rect>[];
        final relay = CanvasViewRelay(
          board: const Rect.fromLTWH(0, 0, 1000, 1000),
          send: (view, {required summon}) => sent.add(view),
          showView: (_) {},
          isBlocked: (_) => false,
          selfId: () => 'me',
          canSend: () => audience,
        );
        relay.reportLocal(const Rect.fromLTWH(10, 10, 100, 100));
        async.elapse(viewSendInterval);
        expect(sent, hasLength(1));

        audience = false;
        async.elapse(viewRepeatInterval * 3);

        expect(sent, hasLength(1), reason: 'repeat ignored canSend');
        relay.dispose();
      });
    },
  );
}
