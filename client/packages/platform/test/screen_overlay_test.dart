// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The overlay's wire shape between Dart and the runner: what `support`
/// answers, what a frame says, and that a runner with no overlay reads as
/// unsupported rather than as an error.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OverlaySupport.fromReply', () {
    test('reads the monitors of a supporting desktop', () {
      final support = OverlaySupport.fromReply({
        'supported': true,
        'monitors': [
          {'x': 0, 'y': 0, 'width': 1920, 'height': 1080, 'primary': true},
          {'x': 1920, 'y': 0, 'width': 1280, 'height': 800, 'primary': false},
        ],
      });
      expect(support.supported, isTrue);
      expect(support.monitors.length, 2);
      expect(support.monitors.first.primary, isTrue);
      expect(support.monitors.last.aspect, closeTo(1.6, 1e-9));
    });

    test('a desktop that cannot host it is unsupported', () {
      expect(
        OverlaySupport.fromReply({'supported': false, 'monitors': <Object>[]})
            .supported,
        isFalse,
      );
      expect(OverlaySupport.fromReply(null).supported, isFalse);
    });

    test('supported with no usable monitor is unsupported', () {
      expect(
        OverlaySupport.fromReply({
          'supported': true,
          'monitors': [
            {'x': 0, 'y': 0, 'width': 0, 'height': 0},
          ],
        }).supported,
        isFalse,
      );
    });
  });

  group('shapes', () {
    test('a stroke carries its points, width, colour and fade', () {
      const shape = OverlayStroke(
        points: [0.1, 0.2, 0.3, 0.4],
        color: Color(0xFFE86A5C),
        alpha: 0.5,
        width: 4,
      );
      expect(shape.toJson(), {
        't': 'stroke',
        'points': [0.1, 0.2, 0.3, 0.4],
        'width': 4.0,
        'color': 0xFFE86A5C,
        'alpha': 0.5,
      });
    });

    test('an ellipse carries its rectangle', () {
      const shape = OverlayEllipse(
        x0: 0.1,
        y0: 0.2,
        x1: 0.3,
        y1: 0.4,
        color: Color(0xFF5B8FD6),
        alpha: 1,
      );
      expect(shape.toJson()['rect'], [0.1, 0.2, 0.3, 0.4]);
      expect(shape.toJson()['t'], 'ellipse');
    });

    test('a note carries its corner and text', () {
      const shape = OverlayNote(
        x: 0.4,
        y: 0.5,
        text: 'look',
        color: Color(0xFFE8B04B),
        alpha: 1,
      );
      expect(shape.toJson()['x'], 0.4);
      expect(shape.toJson()['text'], 'look');
    });
  });

  group('call panel', () {
    const panel = OverlayPanel(
      monitor: 1,
      corner: OverlayCorner.bottomRight,
      rows: [
        OverlayPanelRow(name: 'nick (you)'),
        OverlayPanelRow(name: 'web', speaking: true),
        OverlayPanelRow(name: 'quiet', muted: true, deafened: true),
      ],
      more: 2,
      surface: Color(0xE01F2226),
      border: Color(0xFF2E333A),
      text: Color(0xFFECEDEF),
      textMuted: Color(0xFFA7AEB6),
      accent: Color(0xFF58B4D8),
      danger: Color(0xFFD4756B),
    );

    test('carries the rows, the corner and the colours', () {
      final json = panel.toJson();
      expect(json['monitor'], 1);
      expect(json['corner'], 'bottomRight');
      expect(json['more'], 2);
      expect(json['accent'], 0xFF58B4D8);
      expect((json['rows']! as List)[1], {
        'name': 'web',
        'speaking': true,
        'muted': false,
        'deafened': false,
      });
    });

    test('is equal to a panel that says the same, so a repeat can be skipped',
        () {
      const same = OverlayPanel(
        monitor: 1,
        corner: OverlayCorner.bottomRight,
        rows: [
          OverlayPanelRow(name: 'nick (you)'),
          OverlayPanelRow(name: 'web', speaking: true),
          OverlayPanelRow(name: 'quiet', muted: true, deafened: true),
        ],
        more: 2,
        surface: Color(0xE01F2226),
        border: Color(0xFF2E333A),
        text: Color(0xFFECEDEF),
        textMuted: Color(0xFFA7AEB6),
        accent: Color(0xFF58B4D8),
        danger: Color(0xFFD4756B),
      );
      expect(same, panel);
      expect(same.hashCode, panel.hashCode);
    });

    test('differs when a row starts speaking', () {
      final louder = OverlayPanel(
        monitor: panel.monitor,
        corner: panel.corner,
        rows: [
          panel.rows[0],
          const OverlayPanelRow(name: 'web'),
          panel.rows[2],
        ],
        more: panel.more,
        surface: panel.surface,
        border: panel.border,
        text: panel.text,
        textMuted: panel.textMuted,
        accent: panel.accent,
        danger: panel.danger,
      );
      expect(louder, isNot(panel));
    });
  });

  group('ChannelScreenOverlay', () {
    const channel = MethodChannel(screenOverlayChannelName);
    final calls = <MethodCall>[];

    setUp(calls.clear);
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    void answer(Object? Function(MethodCall call) handler) =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });

    test('a runner with no overlay reads as unsupported', () async {
      expect((await const ChannelScreenOverlay().support()).supported, isFalse);
    });

    test('panel sends the panel, or null to clear it', () async {
      answer((_) => null);
      const overlay = ChannelScreenOverlay();
      await overlay.panel(null);
      expect(calls.single.method, 'panel');
      expect(calls.single.arguments, isNull);
    });

    test('appMonitor reads the runner, and no answer is unknown', () async {
      answer((_) => 1);
      expect(await const ChannelScreenOverlay().appMonitor(), 1);
      answer((_) => -1);
      expect(await const ChannelScreenOverlay().appMonitor(), isNull);
    });

    test('a runner with no overlay answers appMonitor with nothing', () async {
      expect(await const ChannelScreenOverlay().appMonitor(), isNull);
      await const ChannelScreenOverlay().panel(null);
    });

    test('show names the monitors and answers whether it opened', () async {
      answer((_) => true);
      expect(await const ChannelScreenOverlay().show([1, 2]), isTrue);
      expect(calls.single.method, 'show');
      expect(calls.single.arguments, {
        'monitor': 1,
        'monitors': [1, 2]
      });
    });

    test('draw sends every shape as its json', () async {
      answer((_) => null);
      await const ChannelScreenOverlay().draw(const [
        OverlayStroke(
          points: [0.1, 0.1, 0.2, 0.2],
          color: Color(0xFF000000),
          alpha: 1,
        ),
      ]);
      expect(calls.single.method, 'draw');
      final shapes = (calls.single.arguments as Map)['shapes'] as List;
      expect((shapes.single as Map)['t'], 'stroke');
    });

    test('a refusing runner answers false, not an error', () async {
      answer((_) => throw PlatformException(code: 'nope'));
      expect(await const ChannelScreenOverlay().show([0]), isFalse);
    });

    test('hide reaches the runner', () async {
      answer((_) => null);
      await const ChannelScreenOverlay().hide();
      expect(calls.single.method, 'hide');
    });
  });
}
