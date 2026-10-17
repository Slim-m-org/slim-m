// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The predicates that gate a message's destructive actions - edit, delete,
/// pin, report, block. The context-menu widget tests exercise them only
/// through what the menu renders, never as a matrix, so the distinctions that
/// actually matter went unpinned: delete allows the author OR a moderator, but
/// pin allows only the moderator (no author exception), block needs a live
/// author to key on, and every one of them is suppressed while a send is still
/// pending or has failed - a row that was never stored server-side has nothing
/// there to act on.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/features/messages/providers/message_actions.dart';

import 'message_row_harness.dart';

const _me = 'me';
const _mod = Perm.manageMessages;
const _none = 0;

void main() {
  group('canEditMessage: own live message only', () {
    test('the author may edit their own', () {
      expect(canEditMessage(message(authorId: _me), _me), isTrue);
    });
    test(
      'no one may edit another author, even a moderator (not offered here)',
      () {
        expect(canEditMessage(message(authorId: 'other'), _me), isFalse);
      },
    );
    test('a pending or failed send has nothing stored to edit', () {
      expect(
        canEditMessage(message(authorId: _me, pending: true), _me),
        isFalse,
      );
      expect(
        canEditMessage(message(authorId: _me, failed: true), _me),
        isFalse,
      );
    });
  });

  group('canDeleteMessage: own, or MANAGE_MESSAGES', () {
    test('the author may delete their own with no permission', () {
      expect(canDeleteMessage(message(authorId: _me), _me, _none), isTrue);
    });
    test('a moderator may delete another author', () {
      expect(canDeleteMessage(message(authorId: 'other'), _me, _mod), isTrue);
    });
    test('a plain member may not delete another author', () {
      expect(canDeleteMessage(message(authorId: 'other'), _me, _none), isFalse);
    });
    test('a pending or failed send is out of scope', () {
      expect(
        canDeleteMessage(message(authorId: _me, pending: true), _me, _mod),
        isFalse,
      );
      expect(
        canDeleteMessage(message(authorId: _me, failed: true), _me, _mod),
        isFalse,
      );
    });
  });

  group('canManageMessagePin: MANAGE_MESSAGES only, no author exception', () {
    test('a moderator may pin', () {
      expect(canManageMessagePin(message(authorId: 'other'), _mod), isTrue);
    });
    test('the author may not pin their own without the permission', () {
      expect(canManageMessagePin(message(authorId: _me), _none), isFalse);
    });
    test('a pending send cannot be pinned even by a moderator', () {
      expect(
        canManageMessagePin(message(authorId: _me, pending: true), _mod),
        isFalse,
      );
    });
  });

  group(
    'canStartSelectingMessages: MANAGE_MESSAGES only, unlike canDeleteMessage',
    () {
      test('a moderator may start selecting from another author', () {
        expect(
          canStartSelectingMessages(message(authorId: 'other'), _mod),
          isTrue,
        );
      });
      test('the author may not start selecting their own without the '
          'permission, even though canDeleteMessage allows it', () {
        expect(canDeleteMessage(message(authorId: _me), _me, _none), isTrue);
        expect(
          canStartSelectingMessages(message(authorId: _me), _none),
          isFalse,
        );
      });
      test('a plain member gets it on no message at all', () {
        expect(
          canStartSelectingMessages(message(authorId: 'other'), _none),
          isFalse,
        );
      });
      test('a pending send cannot be selected even by a moderator', () {
        expect(
          canStartSelectingMessages(
            message(authorId: _me, pending: true),
            _mod,
          ),
          isFalse,
        );
      });
    },
  );

  group('canReportMessage: any live message not your own', () {
    test('another author may be reported', () {
      expect(canReportMessage(message(authorId: 'other'), _me), isTrue);
    });
    test('your own may not be reported', () {
      expect(canReportMessage(message(authorId: _me), _me), isFalse);
    });
    test('a pending or failed send is not reportable', () {
      expect(
        canReportMessage(message(authorId: 'other', failed: true), _me),
        isFalse,
      );
    });
  });

  group('canBlockMessageAuthor: a live, other author to key on', () {
    test('another author may be blocked', () {
      expect(canBlockMessageAuthor(message(authorId: 'other'), _me), isTrue);
    });
    test('you cannot block yourself', () {
      expect(canBlockMessageAuthor(message(authorId: _me), _me), isFalse);
    });
    test('an anonymized message has no author left to block', () {
      expect(canBlockMessageAuthor(message(authorId: null), _me), isFalse);
    });
    test('a pending or failed send is out of scope', () {
      expect(
        canBlockMessageAuthor(message(authorId: 'other', pending: true), _me),
        isFalse,
      );
    });
  });
}
