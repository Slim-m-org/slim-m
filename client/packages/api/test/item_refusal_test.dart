// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A batch request's error body naming the entries it refused, as the typed exceptions carry it.
library;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Future<void> expectMapped(int status, String body, Matcher matcher) async {
  final api = SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    httpClient: MockClient((_) async => http.Response(body, status)),
  );
  await expectLater(api.version, throwsA(matcher));
}

void main() {
  test('a 409 or 400 names the batch image it refuses', () async {
    await expectMapped(
      409,
      '{"error":"image 3 (zorg): taken","item_index":2,"item_code":"name_taken"}',
      isA<ConflictException>()
          .having((e) => e.item?.index, 'index', 2)
          .having((e) => e.item?.code, 'code', 'name_taken'),
    );
    await expectMapped(
      400,
      '{"error":"image 1 (a): bad","item_index":0,"item_code":"empty"}',
      isA<BadRequestException>()
          .having((e) => e.item?.index, 'index', 0)
          .having((e) => e.item?.code, 'code', 'empty'),
    );
  });

  test('a batch refusal lists every image it refuses', () async {
    await expectMapped(
      400,
      '{"error":"image 2 (a): bad","item_index":1,"item_code":"empty",'
      '"items":[{"index":1,"code":"empty","error":"image 2 (a): bad"},'
      '{"index":4,"code":"name_taken","error":"image 5 (b): taken"},'
      '{"index":"x","code":"empty"}]}',
      isA<BadRequestException>().having(
        (e) => [for (final i in e.items) (i.index, i.code, i.error)],
        'items',
        [
          (1, 'empty', 'image 2 (a): bad'),
          (4, 'name_taken', 'image 5 (b): taken'),
        ],
      ),
    );
    await expectMapped(
      409,
      '{"error":"dup"}',
      isA<ConflictException>().having((e) => e.items, 'items', isEmpty),
    );
    await expectMapped(
      409,
      '{"error":"taken","item_index":2,"item_code":"name_taken"}',
      isA<ConflictException>().having(
        (e) => [for (final i in e.items) (i.index, i.code, i.error)],
        'items',
        [(2, 'name_taken', 'taken')],
      ),
    );
  });

  test('an error body without both item fields names no image', () async {
    await expectMapped(
      409,
      '{"error":"dup"}',
      isA<ConflictException>().having((e) => e.item, 'item', isNull),
    );
    await expectMapped(
      409,
      '{"error":"dup","item_index":1}',
      isA<ConflictException>().having((e) => e.item, 'item', isNull),
    );
    await expectMapped(
      409,
      '{"error":"dup","item_index":-1,"item_code":"name_taken"}',
      isA<ConflictException>().having((e) => e.item, 'item', isNull),
    );
  });
}
