// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of `msg-attachments`: what a message's attachments look
/// like in the real transcript (a gallery that overflows, a file chip, a
/// failed image, a held gif, a data-saver gate, a failed download), at phone
/// and desktop width in both themes. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise each case asserts a clean layout.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/downloads/downloads_controller.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/media_preferences.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_messages_media.dart';
import 'ui_review_messages_support.dart';

const _surface = 'msg-attachments';
const _ada = 'user-ada';

final _gif = animatedGif();

List<api.Message> _one(String text, List<api.Attachment> attachments) => [
  reviewMessage(1, _ada, 'sharing the files from the offsite'),
  reviewMessage(2, _ada, text, attachments: attachments),
];

const _pdf = api.Attachment(
  id: 'doc-agenda',
  filename: 'offsite-agenda.pdf',
  contentType: 'application/pdf',
  size: 482130,
);

const _zip = api.Attachment(
  id: 'doc-photos',
  filename: 'offsite-photos-full-resolution-2026.zip',
  contentType: 'application/zip',
  size: 218103808,
);

const _clip = api.Attachment(
  id: 'clip-demo',
  filename: 'canvas-demo.mp4',
  contentType: 'video/mp4',
  size: 12582912,
);

final _gallery = [
  for (var i = 0; i < 7; i++)
    imageAttachment('trip-$i', 'offsite-${i + 1}.png'),
];

Future<void> _tapChip(ReviewScene scene) async {
  await scene.tester.tap(find.text('offsite-agenda.pdf'));
  await scene.frames(2);
}

Future<void> _setPrefs(
  ReviewScene scene, {
  MediaAutoDownload? download,
  GifAutoplay? gif,
}) async {
  if (download != null) {
    await scene.container
        .read(mediaAutoDownloadControllerProvider.notifier)
        .select(download);
  }
  if (gif != null) {
    await scene.container
        .read(gifAutoplayControllerProvider.notifier)
        .select(gif);
  }
}

typedef _Case = ({
  List<api.Message> messages,
  List<Override> overrides,
  SceneStep? seed,
  SceneStep? act,
});

final _cases = <String, _Case>{
  'gallery-overflow': (
    messages: _one('the whole set, there are a few more in the zip', _gallery),
    overrides: mediaOverrides({
      for (var i = 0; i < 7; i++) 'trip-$i': photo(i),
    }),
    seed: null,
    act: null,
  ),
  'file-chip': (
    messages: _one('agenda and the full-resolution photos', [_pdf, _zip]),
    overrides: const [],
    seed: null,
    act: null,
  ),
  'file-failed': (
    messages: _one('here is the group photo', [
      imageAttachment('fail-1', 'group-photo.png'),
    ]),
    overrides: [
      attachmentPreviewBytesProvider.overrideWith(
        (ref, key) async => throw const api.ForbiddenException(
          'you cannot view this attachment',
        ),
      ),
    ],
    seed: null,
    act: null,
  ),
  'gif-frozen': (
    messages: _one('the demo, on a loop', [
      const api.Attachment(
        id: 'gif-demo',
        filename: 'sun-over-the-ridge.gif',
        contentType: 'image/gif',
        size: 48211,
      ),
    ]),
    overrides: mediaOverrides({'gif-demo': _gif}),
    seed: (scene) => _setPrefs(scene, gif: GifAutoplay.tapToPlay),
    act: null,
  ),
  'data-saver': (
    messages: _one('photo and a clip from the demo', [
      imageAttachment('saver-1', 'offsite-1.png', size: 2411724),
      _clip,
    ]),
    overrides: mediaOverrides({'saver-1': photo(0)}),
    seed: (scene) => _setPrefs(scene, download: MediaAutoDownload.manual),
    act: null,
  ),
  'download-error': (
    messages: _one('agenda for tomorrow', [_pdf]),
    overrides: [
      downloadTargetOpenerProvider.overrideWithValue(
        (filename) async => throw StateError('no writable folder'),
      ),
    ],
    seed: null,
    act: _tapChip,
  ),
};

void main() {
  setUpAll(loadRealFonts);

  for (final entry in _cases.entries) {
    for (final viewport in reviewViewports.keys) {
      testWidgets('${entry.key} at $viewport', (tester) async {
        final spec = entry.value;
        await captureMessages(
          tester,
          surface: _surface,
          state: entry.key,
          viewport: viewport,
          messages: spec.messages,
          overrides: spec.overrides,
          seed: spec.seed,
          act: spec.act,
        );
      });
    }
  }
}
