// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picture a call-panel row carries: a 48px circle of the cached avatar,
/// or the tinted initials disc, baked for real through dart:ui.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/avatar_bytes.dart';
import 'package:slimm_app/src/features/members/providers/avatar_version.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/call_overlay_avatar.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/call_overlay_avatar_render.dart';
import 'package:slimm_design_system/design_system.dart' show avatarTintFor;

const _red = ui.Color(0xFFD03030);

Future<Uint8List> _solidPng(int width, int height, ui.Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = color,
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

class _Baked {
  _Baked(this.width, this.height, this._rgba);

  final int width;
  final int height;
  final ByteData _rgba;

  ui.Color at(int x, int y) {
    final i = (y * width + x) * 4;
    return ui.Color.fromARGB(
      _rgba.getUint8(i + 3),
      _rgba.getUint8(i),
      _rgba.getUint8(i + 1),
      _rgba.getUint8(i + 2),
    );
  }
}

Future<_Baked> _bake(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final rgba = (await image.toByteData())!;
  final baked = _Baked(image.width, image.height, rgba);
  image.dispose();
  codec.dispose();
  return baked;
}

bool _near(ui.Color a, ui.Color b) =>
    (a.r - b.r).abs() < 0.03 &&
    (a.g - b.g).abs() < 0.03 &&
    (a.b - b.b).abs() < 0.03 &&
    a.a > 0.97;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('renderOverlayAvatar', () {
    test('a picture becomes a 48px circle, centre-cropped', () async {
      final wide = await _solidPng(120, 60, _red);
      final baked = await _bake(
        await renderOverlayAvatar(name: 'Riley', tintKey: 'u', picture: wide),
      );
      expect((baked.width, baked.height), (48, 48));
      expect(_near(baked.at(24, 24), _red), isTrue, reason: 'centre');
      expect(_near(baked.at(24, 3), _red), isTrue, reason: 'inside the rim');
      expect(baked.at(0, 0).a, 0, reason: 'corner is outside the circle');
      expect(baked.at(47, 47).a, 0);
    });

    test('with no picture it is a tinted disc with initials', () async {
      final baked = await _bake(
        await renderOverlayAvatar(name: 'Riley', tintKey: 'u-7'),
      );
      expect((baked.width, baked.height), (48, 48));
      expect(_near(baked.at(24, 4), avatarTintFor('u-7')), isTrue);
      expect(baked.at(0, 0).a, 0);
      var inked = 0;
      for (var x = 12; x < 36; x++) {
        for (var y = 14; y < 34; y++) {
          if (_near(baked.at(x, y), const ui.Color(0xFFFFFFFF))) inked++;
        }
      }
      expect(inked, greaterThan(0), reason: 'the initials are drawn in white');
    });

    test('a picture that will not decode falls back to initials', () async {
      final baked = await _bake(
        await renderOverlayAvatar(
          name: 'Riley',
          tintKey: 'u-7',
          picture: Uint8List.fromList([1, 2, 3]),
        ),
      );
      expect(_near(baked.at(24, 4), avatarTintFor('u-7')), isTrue);
    });

    test(
      'a tint follows the user id, so one person keeps one colour',
      () async {
        final a = await _bake(
          await renderOverlayAvatar(name: 'A', tintKey: 'x'),
        );
        final b = await _bake(
          await renderOverlayAvatar(name: 'B', tintKey: 'x'),
        );
        expect(a.at(24, 4), b.at(24, 4));
      },
    );
  });

  group('callOverlayAvatarProvider', () {
    final calls = <({String name, String tintKey, Uint8List? picture})>[];

    ProviderContainer container({int? version, Uint8List? bytes}) {
      calls.clear();
      final c = ProviderContainer(
        overrides: [
          avatarVersionProvider.overrideWith((ref, id) => version),
          avatarBytesProvider.overrideWith((ref, key) async => bytes),
          overlayAvatarRendererProvider.overrideWithValue(({
            required name,
            required tintKey,
            picture,
          }) async {
            calls.add((name: name, tintKey: tintKey, picture: picture));
            return Uint8List.fromList([picture == null ? 0 : 1]);
          }),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    const who = (id: 'u-1', name: 'Riley');

    test('someone with no avatar gets initials baked from their id', () async {
      final c = container();
      final avatar = await c.read(callOverlayAvatarProvider(who).future);
      expect(calls.single.tintKey, 'u-1');
      expect(calls.single.picture, isNull);
      expect(avatar.png, [0]);
    });

    test('someone with an avatar gets their picture baked', () async {
      final bytes = Uint8List.fromList([9, 9]);
      final c = container(version: 3, bytes: bytes);
      c.listen(callOverlayAvatarProvider(who), (_, _) {});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final avatar = await c.read(callOverlayAvatarProvider(who).future);
      expect(calls.last.picture, bytes);
      expect(avatar.png, [1]);
    });

    Future<OverlayAvatar> baked(ProviderContainer c) async {
      c.listen(callOverlayAvatarProvider(who), (_, _) {});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      return c.read(callOverlayAvatarProvider(who).future);
    }

    test(
      'the key tells initials from a picture, and one version from the next',
      () async {
        final bytes = Uint8List.fromList([1]);
        final initials = await baked(container());
        final v3 = await baked(container(version: 3, bytes: bytes));
        final v4 = await baked(container(version: 4, bytes: bytes));
        expect({initials.key, v3.key, v4.key}, hasLength(3));
      },
    );

    test(
      'a rename changes the key, since the initials change with it',
      () async {
        final riley = await baked(container());
        final sam = await container().read(
          callOverlayAvatarProvider((id: 'u-1', name: 'Sam')).future,
        );
        expect(sam.key, isNot(riley.key));
      },
    );
  });
}
