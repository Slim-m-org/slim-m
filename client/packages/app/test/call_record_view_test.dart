// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One stored call record reads differently from each end of the DM, which is
/// the whole reason the server stores an outcome and no wording.
///
/// "Missed call" and "No answer" are the same row seen from two sides, and
/// telling the person who placed the call that they missed it would be a lie
/// the database made unavoidable if the text lived there.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/widgets/call_record_view.dart';

String labelFor(api.CallOutcome? outcome, {required bool caller, int? ms}) =>
    callRecordLabel(outcome: outcome, viewerIsCaller: caller, durationMs: ms);

void main() {
  group('a call nobody answered', () {
    test('is a missed call to the person who was called', () {
      expect(labelFor(api.CallOutcome.timedOut, caller: false), 'Missed call');
    });

    test('is no answer to the person who called', () {
      expect(labelFor(api.CallOutcome.timedOut, caller: true), 'No answer');
    });

    test('a caller who hung up first still leaves the other side a miss', () {
      expect(labelFor(api.CallOutcome.canceled, caller: false), 'Missed call');
      expect(
        labelFor(api.CallOutcome.canceled, caller: true),
        'Call cancelled',
        reason: 'you cannot have missed a call you chose to end',
      );
    });
  });

  test('declining reads as a choice to whoever made it', () {
    expect(
      labelFor(api.CallOutcome.declined, caller: false),
      'You declined this call',
    );
    expect(labelFor(api.CallOutcome.declined, caller: true), 'Call declined');
  });

  group('an answered call', () {
    test('says so without a duration until one is known', () {
      expect(labelFor(api.CallOutcome.answered, caller: true), 'Call');
    });

    test('carries the duration once there is one', () {
      expect(
        labelFor(api.CallOutcome.answered, caller: true, ms: 252000),
        'Call · 4m 12s',
      );
    });

    test('reads the same from both ends, because it happened', () {
      expect(
        labelFor(api.CallOutcome.answered, caller: true, ms: 5000),
        labelFor(api.CallOutcome.answered, caller: false, ms: 5000),
      );
    });
  });

  group('duration', () {
    test('drops the minutes rather than showing a zero', () {
      expect(formatCallDuration(12000), '12s');
    });

    test('keeps seconds alongside minutes', () {
      expect(formatCallDuration(61000), '1m 1s');
      expect(formatCallDuration(600000), '10m 0s');
    });
  });

  /// Forward compatibility: a newer server can name an outcome this build has
  /// never heard of, and the message must not render as an empty bubble.
  test('an outcome this build does not know still reads as a call', () {
    expect(api.CallOutcome.fromWire('transcribed'), isNull);
    expect(labelFor(null, caller: false), 'Call');
  });

  test('every wire spelling the schema lists is understood', () {
    for (final wire in ['answered', 'declined', 'canceled', 'timed_out']) {
      expect(
        api.CallOutcome.fromWire(wire),
        isNotNull,
        reason: '$wire is in openapi.yaml and must not render as unknown',
      );
    }
  });

  test('only an answered call counts as having happened', () {
    expect(api.CallOutcome.answered.wasMissed, isFalse);
    for (final outcome in api.CallOutcome.values) {
      if (outcome == api.CallOutcome.answered) continue;
      expect(
        outcome.wasMissed,
        isTrue,
        reason: '${outcome.name} never connected',
      );
    }
  });
}
