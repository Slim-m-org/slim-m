// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The report card's name labels resolve an id through a profile map that may
/// not hold it yet, and the states must not blur: an id absent from the map is
/// still *loading*, while an id present with a null value is a *deleted*
/// account - a moderator seeing "Deleted account" for someone whose profile
/// simply has not arrived would be misled. authorHeadline also separates a
/// null id (the message was hard-deleted or anonymized) from a deleted account.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/report_card_labels.dart';

api.UserProfile _alice() => const api.UserProfile(
  id: 'u1',
  username: 'alice',
  displayName: 'Alice',
  createdAt: 0,
);

void main() {
  final present = {'u1': _alice()};
  final loadedButDeleted = <String, api.UserProfile?>{'u1': null};
  final notFetched = <String, api.UserProfile?>{};

  group('reporterLabel', () {
    test('shows the name when present', () {
      expect(reporterLabel('u1', present), 'Alice');
    });
    test('an id not yet fetched is still loading, not deleted', () {
      expect(reporterLabel('u1', notFetched), 'Loading...');
    });
    test('a null id and a loaded-but-gone account read the same', () {
      expect(reporterLabel(null, notFetched), 'a deleted account');
      expect(reporterLabel('u1', loadedButDeleted), 'a deleted account');
    });
  });

  group('subjectHeadline', () {
    test('shows the name, or loading, or deleted for its three states', () {
      expect(subjectHeadline('u1', present), 'Alice');
      expect(subjectHeadline('u1', notFetched), 'Loading...');
      expect(subjectHeadline('u1', loadedButDeleted), 'Deleted account');
    });
  });

  group('authorHeadline', () {
    test('a null id is not a failed lookup but a hard-deleted message', () {
      expect(
        authorHeadline(null, notFetched),
        'Author no longer on this Space',
      );
    });
    test('the fetched, loading, and deleted states each read distinctly', () {
      expect(authorHeadline('u1', present), 'Alice');
      expect(authorHeadline('u1', notFetched), 'Loading...');
      expect(authorHeadline('u1', loadedButDeleted), 'Deleted account');
    });
  });
}
