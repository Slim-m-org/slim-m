// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of `msg-cards`: the cards a message carries under its
/// text (link previews, a playable video, an embed, a forward, a call
/// record), in the real transcript at phone and desktop width in both themes.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise each case
/// asserts a clean layout.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/link_preview.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_messages_media.dart';
import 'ui_review_messages_support.dart';

const _surface = 'msg-cards';
const _ada = 'user-ada';
const _nick = 'user-nick';

const _articleUrl = 'https://example.org/notes/why-seq-beats-timestamps';
const _videoUrl = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

Override _preview(String url, api.LinkPreview preview) =>
    linkPreviewProvider(url).overrideWith((ref) async => preview);

Override _image(String token, Uint8List bytes) =>
    linkPreviewImageBytesProvider(token).overrideWith((ref) async => bytes);

final _article = photo(1, w: 1200, h: 630);
final _thumb = photo(2, w: 1280, h: 720);

const _embed = api.Embed(
  title: 'Deploy 2.14.0 finished',
  description: 'All 3 services rolled out with no failed health checks.',
  url: 'https://deploys.example.org/runs/2140',
  accent: api.EmbedAccent.green,
  authorName: 'CI deploys',
  fields: [
    api.EmbedField(name: 'Service', value: 'slimm-server', inline: true),
    api.EmbedField(name: 'Took', value: '4 min 12 s', inline: true),
    api.EmbedField(name: 'Commit', value: 'dcca8a2', inline: true),
    api.EmbedField(
      name: 'Notes',
      value: 'Migrations 0090 and 0091 applied. No downtime.',
      inline: false,
    ),
  ],
  footerText: 'deploys - main',
  timestamp: 1753600000000 + 120000,
  imageToken: 'embed-img',
);

const _origin = api.ForwardedMessage(
  messageId: 'm-2',
  channelId: 'c-design',
  authorId: _ada,
  authorDisplayName: 'Ada Lovelace',
  authorAvatarUpdatedAt: null,
  createdAt: 1753600000000,
  content:
      'The spacing on the settings pane is off by a hair at 800, see the '
      'screenshot and the spec sheet.',
);

typedef _Case = ({
  List<api.Message> messages,
  String route,
  List<Override> overrides,
});

List<api.Message> _lead() => [
  reviewMessage(1, _nick, 'anyone seen a good write-up on this?'),
];

final _cases = <String, _Case>{
  'link-preview': (
    route: '/channels/c-general',
    messages: [
      ..._lead(),
      reviewMessage(2, _ada, 'this one is good: $_articleUrl'),
    ],
    overrides: [
      _preview(
        _articleUrl,
        const api.LinkPreview(
          url: _articleUrl,
          siteName: 'Example Engineering',
          title: 'Why a per-channel seq beats timestamps for ordering',
          description:
              'Clocks drift and writers race. A monotonic sequence per '
              'channel gives every client the same answer without trusting '
              'any one clock.',
          imageToken: 'lp-article',
        ),
      ),
      _image('lp-article', _article),
    ],
  ),
  'link-preview-no-image': (
    route: '/channels/c-general',
    messages: [
      ..._lead(),
      reviewMessage(2, _ada, 'and the short version: $_articleUrl'),
    ],
    overrides: [
      _preview(
        _articleUrl,
        const api.LinkPreview(
          url: _articleUrl,
          siteName: 'Example Engineering',
          title: 'Why a per-channel seq beats timestamps for ordering',
          description: 'Clocks drift and writers race.',
        ),
      ),
    ],
  ),
  'youtube': (
    route: '/channels/c-general',
    messages: [
      ..._lead(),
      reviewMessage(2, _ada, 'the talk from last week: $_videoUrl'),
    ],
    overrides: [
      _preview(
        _videoUrl,
        const api.LinkPreview(
          url: _videoUrl,
          siteName: 'YouTube',
          title: 'Sequencing distributed writes without a clock',
          videoProvider: api.LinkPreviewVideoProvider.youtube,
          videoId: 'dQw4w9WgXcQ',
          authorName: 'Systems Weekly',
          authorUrl: 'https://www.youtube.com/@systemsweekly',
          imageToken: 'lp-video',
        ),
      ),
      _image('lp-video', _thumb),
    ],
  ),
  'embed': (
    route: '/channels/c-general',
    messages: [
      ..._lead(),
      reviewMessage(
        2,
        'user-hook',
        '',
        embeds: const [_embed],
        webhookUsername: 'CI deploys',
      ),
    ],
    overrides: [_image('embed-img', _article)],
  ),
  'forwarded': (
    route: '/channels/c-general',
    messages: [
      ..._lead(),
      reviewMessage(
        2,
        _nick,
        'passing this along, it affects the rail work',
        forwarded: _origin,
      ),
    ],
    overrides: const [],
  ),
  'forwarded-attachments': (
    route: '/channels/c-general',
    messages: [
      ..._lead(),
      reviewMessage(
        2,
        _nick,
        'the screenshot and the spec sheet came with it',
        forwarded: _origin,
        attachments: [
          imageAttachment('fwd-shot', 'settings-pane-800.png'),
          const api.Attachment(
            id: 'fwd-spec',
            filename: 'settings-spacing-spec.pdf',
            contentType: 'application/pdf',
            size: 482130,
          ),
        ],
      ),
    ],
    overrides: mediaOverrides({'fwd-shot': photo(0)}),
  ),
  'call-record': (
    route: '/channels/c-dm-ada',
    messages: [
      reviewMessage(
        1,
        _ada,
        'got a minute to look at the overwrites screen?',
        channelId: 'c-dm-ada',
      ),
      reviewMessage(
        2,
        _ada,
        '',
        channelId: 'c-dm-ada',
        call: const api.CallRecord(
          callerId: _ada,
          outcome: api.CallOutcome.answered,
          durationMs: 1425000,
        ),
      ),
      reviewMessage(
        3,
        _ada,
        '',
        channelId: 'c-dm-ada',
        call: const api.CallRecord(
          callerId: _ada,
          outcome: api.CallOutcome.timedOut,
        ),
      ),
    ],
    overrides: const [],
  ),
};

void main() {
  setUpAll(() async {
    await loadRealFonts();
    await loadEmojiFont();
  });

  for (final entry in _cases.entries) {
    for (final viewport in reviewViewports.keys) {
      testWidgets('${entry.key} at $viewport', (tester) async {
        final spec = entry.value;
        await captureMessages(
          tester,
          surface: _surface,
          state: entry.key,
          viewport: viewport,
          route: spec.route,
          messages: spec.messages,
          overrides: spec.overrides,
        );
      });
    }
  }
}
