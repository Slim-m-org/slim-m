// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [extractLinkPreviewUrls]: which URLs a message's content hands
/// to the transcript's preview cards, in what order, and capped how.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_inline.dart';
import 'package:slimm_app/src/features/messages/widgets/message_parse_cache.dart';

void main() {
  test('a message with no URL yields nothing', () {
    expect(extractLinkPreviewUrls('just some text'), isEmpty);
  });

  test('a URL in angle brackets is a link with no card', () {
    expect(
      extractLinkPreviewUrls('read <https://example.com/a> first'),
      isEmpty,
    );
    expect(
      extractLinkPreviewUrls('<https://example.com/a> and https://b.example'),
      ['https://b.example'],
    );
  });

  test('angle brackets render the link without them', () {
    final nodes = parseInline('see <https://example.com/a>');

    expect(nodes.whereType<InlineLink>().single.url, 'https://example.com/a');
    expect(nodes.whereType<InlineLink>().single.noPreview, isTrue);
    expect(nodes.whereType<InlineText>().single.text, 'see ');
  });

  test('a bare URL is extracted', () {
    expect(extractLinkPreviewUrls('see https://example.com/page'), [
      'https://example.com/page',
    ]);
  });

  test(
    'trailing sentence punctuation is trimmed, matching the body render',
    () {
      expect(extractLinkPreviewUrls('check this out: https://example.com.'), [
        'https://example.com',
      ]);
    },
  );

  test('multiple URLs are capped at the default of 2', () {
    const content =
        'https://a.example https://b.example https://c.example https://d.example';
    expect(extractLinkPreviewUrls(content), [
      'https://a.example',
      'https://b.example',
    ]);
  });

  test('a caller can widen or narrow the cap', () {
    const content = 'https://a.example https://b.example https://c.example';
    expect(extractLinkPreviewUrls(content, max: 1), ['https://a.example']);
    expect(extractLinkPreviewUrls(content, max: 3), [
      'https://a.example',
      'https://b.example',
      'https://c.example',
    ]);
  });

  test('the same URL repeated is only returned once', () {
    expect(
      extractLinkPreviewUrls('https://example.com and https://example.com'),
      ['https://example.com'],
    );
  });

  test('a URL nested inside bold or italic markdown is still found', () {
    expect(extractLinkPreviewUrls('**https://example.com**'), [
      'https://example.com',
    ]);
    expect(extractLinkPreviewUrls('*see https://example.com*'), [
      'https://example.com',
    ]);
  });

  test('a URL hidden in a spoiler is not previewed', () {
    // An open card would show the title/image the spoiler exists to hide.
    expect(extractLinkPreviewUrls('||https://example.com||'), isEmpty);
    expect(
      extractLinkPreviewUrls('before ||https://secret.example|| after'),
      isEmpty,
    );
  });

  test('a URL inside a fenced code block gets no card', () {
    const fenced =
        'log:\n```\nfetch https://in.example/x\n```\nsee https://out.example';
    expect(extractLinkPreviewUrls(fenced), ['https://out.example']);
    expect(extractLinkPreviewUrls('```\nhttps://in.example\n```'), isEmpty);
  });

  test('an unclosed fence is plain text, so its URL still counts', () {
    expect(extractLinkPreviewUrls('```\nhttps://a.example'), [
      'https://a.example',
    ]);
  });

  test('the cached lookup returns the one parsed list for a body', () {
    const body = 'see https://cache.example/a';
    expect(
      identical(cachedLinkPreviewUrls(body), cachedLinkPreviewUrls(body)),
      isTrue,
    );
  });
}
