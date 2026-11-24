// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `PATCH /roles/reorder`: the order the caller started from travels with it.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:test/test.dart';

void main() {
  test('a reorder sends the order it started from', () async {
    Map<String, dynamic>? body;
    final api = testApi((request) async {
      expect(request.method, 'PATCH');
      expect(request.url.path, '/roles/reorder');
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response('[]', 200);
    });
    await api.reorderRoles(['b', 'a'], expectedRoleIds: ['a', 'b']);
    expect(body, {
      'role_ids': ['b', 'a'],
      'expected_role_ids': ['a', 'b'],
    });
  });

  test('a reorder without a starting order leaves the field out', () async {
    Map<String, dynamic>? body;
    final api = testApi((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response('[]', 200);
    });
    await api.reorderRoles(['b', 'a']);
    expect(body, {
      'role_ids': ['b', 'a'],
    });
  });
}
