// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [describeApiFailure] is the one place any caller, guarded by `runGuarded`
/// or not, turns an [ApiException] into a sentence. This pins the mapping
/// directly, beneath `run_guarded_test.dart`'s behavioural tests.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/api_failure.dart';
import 'package:slimm_app/src/permissions.dart';

void main() {
  test('a transport failure never leaks the exception string', () {
    final message = describeApiFailure(
      'join the call',
      const api.TransportException(
        'POST /voice/token failed: SocketException: refused',
      ),
    );
    expect(message, isNot(contains('SocketException')));
    expect(message, isNot(contains('POST /voice/token')));
    expect(message, contains('the server could not be reached'));
    expect(message, contains('Nothing was changed'));
  });

  test('a bad request keeps the server\'s own reason, sentence-cased', () {
    expect(
      describeApiFailure(
        'create the role',
        const api.BadRequestException('name must be 1 to 32 characters'),
      ),
      'Could not create the role. Name must be 1 to 32 characters.',
    );
  });

  test('a 502 from the module registry keeps the server\'s reason', () {
    expect(
      describeApiFailure(
        'install Dice',
        const api.ServerException('name "co llide" must be one keyword', 502),
      ),
      'Could not install Dice. Name "co llide" must be one keyword.',
    );
  });

  test('a conflict keeps the server\'s own reason, sentence-cased', () {
    expect(
      describeApiFailure(
        'set the overwrite',
        const api.ConflictException('already exists'),
      ),
      'Could not set the overwrite. Already exists.',
    );
  });

  group('sentenceCase', () {
    test('capitalizes the first letter and adds a trailing period', () {
      expect(
        sentenceCase('password must be 8 to 1024 characters'),
        'Password must be 8 to 1024 characters.',
      );
    });

    test('leaves terminal punctuation alone rather than doubling it', () {
      expect(sentenceCase('already ends cleanly.'), 'Already ends cleanly.');
      expect(sentenceCase('is this it?'), 'Is this it?');
      expect(sentenceCase('really!'), 'Really!');
    });

    test('an empty string stays empty', () {
      expect(sentenceCase(''), '');
    });

    test(
      'a string already capitalized keeps its own casing past the first letter',
      () {
        expect(
          sentenceCase('nick-c is not a valid username'),
          'Nick-c is not a valid username.',
        );
      },
    );
  });

  test('a forbidden that names missing permissions says which', () {
    final message = describeApiFailure(
      'save the permissions grid',
      api.ForbiddenException(
        'cannot grant a permission you do not hold',
        missingPermissions: Perm.manageRoles,
      ),
    );
    expect(message, contains('you cannot grant Manage roles'));
  });

  test('a forbidden and an unauthorized read differently', () {
    final forbidden = describeApiFailure(
      'delete the role',
      const api.ForbiddenException('nope'),
    );
    final unauthorized = describeApiFailure(
      'delete the role',
      const api.UnauthorizedException('nope'),
    );
    expect(forbidden, contains('not allowed'));
    expect(unauthorized, contains('signed out'));
    expect(unauthorized, isNot(contains('not allowed')));
  });

  test('a rate limit and an unnamed server error each name the action', () {
    for (final thrown in <api.ApiException>[
      const api.RateLimitedException('slow down'),
      const api.ServerException('boom', 500),
      const api.UnavailableException('busy'),
      const api.NotConfiguredException('no sfu'),
      const api.NotFoundException('gone'),
    ]) {
      expect(
        describeApiFailure('save the change', thrown),
        contains('save the change'),
        reason: '$thrown',
      );
    }
  });

  test('a slow-mode refusal shows the server\'s own wait time, not the '
      'generic rate-limit copy', () {
    final message = describeApiFailure(
      'send the message',
      const api.RateLimitedException(
        'slow mode: wait 4s before sending again',
        retryAfter: Duration(seconds: 4),
      ),
    );
    expect(message, contains('Slow mode'));
    expect(message, contains('4s'));
    expect(message, isNot(contains('too many requests')));
  });

  test('a 413 says the file is too big and a 507 says storage is out', () {
    expect(
      describeApiFailure(
        'attach the file',
        const api.ServerException('x', 413),
      ),
      'Could not attach the file: it is too big.',
    );
    expect(
      describeApiFailure(
        'attach the file',
        const api.ServerException('x', 507),
      ),
      'Could not attach the file: this server has no storage left. '
      'Tell an admin.',
    );
  });
}
