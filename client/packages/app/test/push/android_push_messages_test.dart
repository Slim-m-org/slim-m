// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the FCM data-message-to-notification mapping: the two kinds
/// that should alert someone with a plain notification, the one that rings
/// as a call instead, and every kind (including none at all) that must stay
/// silent.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/push/android_push_messages.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  group('genericAlertTextFor', () {
    test('message gets the same fixed line iOS shows', () {
      expect(genericAlertTextFor('message'), 'New message');
    });

    test('mention gets its own fixed line, distinct from a plain message', () {
      expect(genericAlertTextFor('mention'), 'You were mentioned');
    });

    test('security gets a fixed line matching the one iOS shows', () {
      expect(genericAlertTextFor('security'), 'New sign-in to your account');
    });

    test('call_end stays silent as a plain alert', () {
      expect(genericAlertTextFor('call_end'), isNull);
    });

    test('call stays silent here: it rings through its own path', () {
      expect(genericAlertTextFor('call'), isNull);
    });

    test('wake stays silent: it is a background sync hint, not an alert', () {
      expect(genericAlertTextFor('wake'), isNull);
    });

    test('an unrecognised kind stays silent rather than guessing', () {
      expect(genericAlertTextFor('something-future-and-unknown'), isNull);
    });

    test('a missing kind stays silent rather than throwing', () {
      expect(genericAlertTextFor(null), isNull);
    });
  });

  group('genericAlertChannelFor', () {
    test('message posts through the messages channel', () {
      expect(genericAlertChannelFor('message'), LocalAlertChannel.messages);
    });

    test('mention posts through its own, separate channel', () {
      expect(genericAlertChannelFor('mention'), LocalAlertChannel.mentions);
    });

    test('security posts through its own channel', () {
      expect(genericAlertChannelFor('security'), LocalAlertChannel.security);
    });

    test('a kind with no text has no channel either', () {
      expect(genericAlertChannelFor('wake'), isNull);
      expect(genericAlertChannelFor(null), isNull);
    });
  });

  group('callerNameFor', () {
    test('a well-formed payload is shown verbatim', () {
      expect(callerNameFor({'caller': 'Alice'}), 'Alice');
    });

    test('an empty payload falls back to the unknown-caller label', () {
      expect(callerNameFor({}), unknownCaller);
    });

    test('a non-string caller falls back rather than throwing', () {
      expect(callerNameFor({'caller': 42}), unknownCaller);
    });

    test('an empty string caller falls back too', () {
      expect(callerNameFor({'caller': ''}), unknownCaller);
    });
  });

  group('callIdFor', () {
    test('a well-formed call_id is used as-is', () {
      expect(callIdFor({'call_id': 'call-123'}), 'call-123');
    });

    test('a missing call_id still gets a call, not a drop', () {
      expect(callIdFor({}), isNotEmpty);
    });

    test('a non-string call_id still gets a call, not a drop', () {
      expect(callIdFor({'call_id': 42}), isNotEmpty);
    });

    test('the same payload reports the same id, not a fresh one each time', () {
      final data = {'call_id': 'call-123'};
      expect(callIdFor(data), callIdFor(data));
    });

    test('two missing-id payloads still get different ids', () {
      // Two unrelated malformed payloads must not collide into one call.
      expect(callIdFor({}), isNot(callIdFor({})));
    });
  });

  group('actionFor', () {
    test('message becomes a generic alert with the fixed line', () {
      final action = actionFor({'kind': 'message'});
      expect(action, isA<PushActionGenericAlert>());
      expect((action as PushActionGenericAlert).text, 'New message');
      expect(action.channel, LocalAlertChannel.messages);
    });

    test('mention becomes a generic alert on its own channel', () {
      final action = actionFor({'kind': 'mention'});
      expect(action, isA<PushActionGenericAlert>());
      expect(
        (action as PushActionGenericAlert).channel,
        LocalAlertChannel.mentions,
      );
    });

    test('security becomes a generic alert on the security channel', () {
      final action = actionFor({'kind': 'security', 'payload': 'sealed'});
      expect(action, isA<PushActionGenericAlert>());
      final alert = action as PushActionGenericAlert;
      expect(alert.text, 'New sign-in to your account');
      expect(alert.channel, LocalAlertChannel.security);
    });

    test('call_end becomes an end-call action, not an alert or a ring', () {
      expect(actionFor({'kind': 'call_end'}), isA<PushActionEndCall>());
      expect(
        actionFor({'kind': 'call_end', 'payload': 'sealed'}),
        isA<PushActionEndCall>(),
      );
    });

    test('call becomes an incoming-call action, not a generic alert', () {
      final action = actionFor({'kind': 'call', 'caller': 'Alice'});
      expect(action, isA<PushActionIncomingCall>());
      expect((action as PushActionIncomingCall).callerName, 'Alice');
    });

    test('a call payload with no caller still becomes an incoming call', () {
      final action = actionFor({'kind': 'call'});
      expect(action, isA<PushActionIncomingCall>());
      expect((action as PushActionIncomingCall).callerName, unknownCaller);
    });

    test('wake stays a no-op action rather than any kind of alert', () {
      expect(actionFor({'kind': 'wake'}), isA<PushActionNone>());
    });

    test('a missing kind stays a no-op action rather than throwing', () {
      expect(actionFor({}), isA<PushActionNone>());
    });
  });
}
