// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared fixtures for the two suites that pump a [Composer]: its send paths
/// and its affordances (attach a file, insert a Space emoji).
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it. It
/// exists because both suites need the same typing seam stubbed, the same
/// signed-in session, the same fake file picker and the same upload route,
/// none of which either suite is actually about.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart' show XFile;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/typing_controller.dart';
import 'package:slimm_app/src/widgets/composer.dart';
import 'package:slimm_app/src/widgets/composer_clipboard_image.dart';
import 'package:slimm_app/src/widgets/emoji_picker_grid.dart';
import 'package:slimm_app/src/widgets/photo_library.dart';
import 'package:slimm_design_system/design_system.dart';

/// Stands in for the real controller, which would open a websocket
/// subscription the moment the first keystroke reaches it.
class NoopTyping extends StateNotifier<Set<String>>
    implements TypingController {
  NoopTyping() : super(const {});

  @override
  void notifyTyping() {}
}

/// Records what the composer handed its `onSend`.
class Sends {
  int count = 0;
  List<String> ids = const [];

  Future<void> call(List<String> attachmentIds) async {
    count += 1;
    ids = attachmentIds;
  }
}

/// Answers the picker without a platform channel. `FilePicker.pickFiles`
/// delegates to this instance, and extending (never implementing) the
/// interface is what satisfies its own token check.
class FakePicker extends FilePickerPlatform {
  FakePicker(this.file, {this.failure});

  /// Null stands for a cancelled pick.
  final PlatformFile? file;

  /// Non-null makes the pick throw this instead of answering, which is what a
  /// missing portal or a refused permission does on a real device. The
  /// composer catches that separately from a cancel, so it needs its own case.
  final Object? failure;

  int calls = 0;

  /// What the most recent call actually asked for, so a test can tell the
  /// composer's two attach routes apart without a platform channel.
  FileType? lastType;

  /// The extension filter of the most recent call, for the custom type.
  List<String>? lastAllowedExtensions;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls += 1;
    lastType = type;
    lastAllowedExtensions = allowedExtensions;
    if (failure != null) throw failure!;
    return file;
  }
}

/// A picked file that holds its bytes in memory, so `readAsBytes` never
/// touches the filesystem.
final class FakePlatformFile extends PlatformFile {
  FakePlatformFile(this.name, this._bytes);

  @override
  final String name;

  final Uint8List _bytes;

  @override
  Uri get uri => Uri.parse('file:///fake/$name');

  @override
  XFile get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => _bytes.length;

  @override
  Future<int?> length() async => _bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => _bytes;

  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(_bytes);
}

/// A pick that resolves, carrying its own bytes so `readAsBytes` never
/// touches the filesystem.
PlatformFile pickedFile() =>
    FakePlatformFile('holiday.png', Uint8List.fromList([1, 2, 3, 4]));

/// Installs a fake picker for one test and puts the real one back after, so a
/// later test in the same process is not left with this one's fake.
FakePicker usePicker(PlatformFile? file, {Object? failure}) {
  final previous = FilePickerPlatform.instance;
  final picker = FakePicker(file, failure: failure);
  FilePickerPlatform.instance = picker;
  addTearDown(() => FilePickerPlatform.instance = previous);
  return picker;
}

/// Enough of a session for the upload to be attempted at all: an unsigned-in
/// client refuses it before the request is ever built.
const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A 1x1 transparent PNG: real bytes, so a custom emoji tile decodes rather
/// than throwing.
final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

api.CustomEmoji custom(String name) =>
    api.CustomEmoji(id: 'e-$name', name: name, uploaderId: 'u1', createdAt: 1);

/// The real server echoes back whatever `filename` a caller uploaded with
/// (sanitised, but these names all already are), never a fixed one; every
/// fake upload route below does the same, or a test asserting on the name
/// the composer shows would pass no matter what was actually picked.
String _echoedFilename(http.Request request) =>
    request.url.queryParameters['filename'] ?? 'upload.bin';

/// An api whose only live route is the attachment upload the composer makes.
api.SlimmApi _uploadingApi(Ref ref) => api.SlimmApi(
  baseUrl: Uri.parse('http://localhost:8080'),
  session: ref.watch(sessionProvider),
  httpClient: MockClient((request) async {
    if (request.method == 'POST' && request.url.path == '/attachments') {
      return http.Response(
        jsonEncode({
          'id': 'a1',
          'filename': _echoedFilename(request),
          'content_type': 'image/png',
          'size': 4,
        }),
        201,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 404, headers: {'content-type': 'text/plain'});
  }),
);

/// Like [_uploadingApi], except the upload answers nothing until [gate]
/// completes - so a test can observe the pending state deterministically
/// rather than racing a fake network's own timing.
api.SlimmApi Function(Ref) gatedUploadApi(Completer<void> gate) =>
    (ref) => api.SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: ref.watch(sessionProvider),
      httpClient: MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/attachments') {
          await gate.future;
          return http.Response(
            jsonEncode({
              'id': 'a1',
              'filename': _echoedFilename(request),
              'content_type': 'image/png',
              'size': 4,
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{}',
          404,
          headers: {'content-type': 'text/plain'},
        );
      }),
    );

/// An api whose attachment upload fails once, a 507 (the ceiling a full
/// volume answers with, never confused for a bad file), then succeeds - so
/// a test can drive a real failure-then-retry-then-success cycle
/// deterministically. A fresh closure per call, so two tests never share
/// the attempt count.
api.SlimmApi Function(Ref) flakyUploadApi() {
  var attempts = 0;
  return (ref) => api.SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: ref.watch(sessionProvider),
    httpClient: MockClient((request) async {
      if (request.method != 'POST' || request.url.path != '/attachments') {
        return http.Response(
          '{}',
          404,
          headers: {'content-type': 'text/plain'},
        );
      }
      attempts += 1;
      if (attempts == 1) {
        return http.Response(
          jsonEncode({'error': 'the server has no space left for uploads'}),
          507,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'id': 'a1',
          'filename': _echoedFilename(request),
          'content_type': 'image/png',
          'size': 4,
        }),
        201,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
}

/// [customEmoji] null leaves the list provider alone, which is the state a
/// suite that has nothing to do with emoji sees: an unfetchable list.
Widget composerHarness({
  required TextEditingController controller,
  required Sends sends,
  required TargetPlatform platform,
  String channelId = 'c1',
  String channelName = 'general',
  List<api.CustomEmoji>? customEmoji,
  FakeClipboardPaste? clipboardPaste,
  api.SlimmApi Function(Ref)? apiBuilder,

  /// A sibling of the real [Composer] in the same `ProviderScope`, for a
  /// suite that needs to reach provider state the composer registers into
  /// (`composer_attachment_drop_test.dart`'s own drop-target probe) rather
  /// than anything visible in the widget tree.
  Widget extra = const SizedBox.shrink(),

  /// False unmounts [Composer] while keeping [extra] and the rest of this
  /// tree in place - a second `pumpWidget` with this flipped is how
  /// `composer_attachment_drop_test.dart` proves the registration a
  /// composer makes is also the one it clears on its own way out.
  bool mountComposer = true,

  /// Appended after this harness's own fixed overrides, so a suite that
  /// needs one more (`composer_slow_mode_test.dart`'s own
  /// `slowModeRemainingSecondsProvider`) does not have to rebuild the whole
  /// tree by hand.
  List<Override> extraOverrides = const [],
}) {
  return ProviderScope(
    overrides: [
      typingControllerProvider.overrideWith((ref, channelId) => NoopTyping()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith(apiBuilder ?? _uploadingApi),
      if (customEmoji != null)
        customEmojiProvider.overrideWith((ref) => customEmoji),
      customEmojiImageProvider.overrideWith((ref, id) => _png),
      photoLibraryProvider.overrideWithValue(null),
      ...extraOverrides,
    ],
    child: MaterialApp(
      theme: buildTheme(
        Brightness.light,
        AppTokens.light,
      ).copyWith(platform: platform),
      home: Scaffold(
        body: Column(
          children: [
            const Spacer(),
            if (mountComposer)
              Composer(
                controller: controller,
                channelId: channelId,
                channelName: channelName,
                onSend: sends.call,
                clipboardPasteStart:
                    clipboardPaste?.start ?? startClipboardImagePaste,
                clipboardPasteStop:
                    clipboardPaste?.stop ?? stopClipboardImagePaste,
              ),
            extra,
          ],
        ),
      ),
    ),
  );
}

/// Stands in for the real browser `paste` listener a widget test cannot
/// produce: [start] just remembers the callback so a test can invoke it
/// directly, as though an image had really been pasted. [stop] mirrors the
/// real implementations' own ownership check - only the caller that is
/// still the registered one can disarm it - so a test built on this fake
/// gets the same protection the real race fix added.
class FakeClipboardPaste {
  PastedImageHandler? _onImage;
  int stopCalls = 0;

  void start(PastedImageHandler onImage) => _onImage = onImage;

  void stop(PastedImageHandler onImage) {
    stopCalls += 1;
    // == rather than identical(): two tear-offs of one instance method are == but never identical.
    if (_onImage == onImage) _onImage = null;
  }

  /// True only while the composer is actually listening, i.e. its field has
  /// focus; a test asserts this to prove the seam is armed and disarmed
  /// with focus rather than left running for the widget's whole life.
  bool get listening => _onImage != null;

  void paste(Uint8List bytes, String filename) =>
      _onImage?.call(bytes, filename);
}

Finder get sendButton => find.ancestor(
  of: find.byIcon(AppIcons.send),
  matching: find.byType(AppIconButton),
);

Finder get attachButton => find.byWidgetPredicate(
  (w) => w is AppIconButton && w.semanticLabel == 'Attach a file',
);

/// The composer's picker button, whichever of its two labels it carries.
///
/// It says "Insert emoji or a GIF" where the deployment has a gif provider
/// and "Insert emoji" where it does not, because there is one button now and
/// the label has to be true in both configurations. Matching either keeps
/// this finder about the button's role rather than its wording.
Finder get emojiButton => find.byWidgetPredicate(
  (w) =>
      w is AppIconButton &&
      (w.semanticLabel == 'Insert emoji' ||
          w.semanticLabel == 'Insert emoji or a GIF'),
);

/// Opens the composer's picker and switches it to the GIFs tab.
///
/// There is no separate GIF button any more - one button opens the panel on
/// Emoji, and the tabs carry the rest - so a test that wants gifs takes the
/// route a person now takes.
Future<void> openGifTab(WidgetTester tester) async {
  await tester.tap(emojiButton);
  await tester.pumpAndSettle();
  await tester.tap(find.text('GIFs'));
  await tester.pumpAndSettle();
}

/// Whether this deployment's picker offers gifs at all: the tab is absent
/// without a provider, which is what the vanished GIF button used to show.
Finder get gifTab => find.text('GIFs');

Finder get moreActionsButton => find.byWidgetPredicate(
  (w) => w is AppIconButton && w.semanticLabel == 'More actions',
);

bool fieldHasFocus(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus;

List<String> gridTokens(WidgetTester tester) => tester
    .widget<EmojiGrid>(find.byType(EmojiGrid))
    .emoji
    .map((e) => e.token)
    .toList();
