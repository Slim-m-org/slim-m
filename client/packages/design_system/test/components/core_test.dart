// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, Widget child, {AppTokens? tokens}) {
  final t = tokens ?? AppTokens.light;
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, t),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  group('AppStatusDot', () {
    test('every state maps to its own shape', () {
      final shapes =
          AppStatusDot.shapeOf.keys.map((s) => AppStatusDot.shapeOf[s]).toSet();
      expect(
        shapes.length,
        AppStatusDot.shapeOf.length,
        reason: 'colour alone must never carry presence; two states sharing a '
            'shape would collapse under greyscale',
      );
    });

    for (final status in AppStatusDot.shapeOf.keys) {
      testWidgets('$status renders the shape it is mapped to', (tester) async {
        await _pump(tester, AppStatusDot(status: status));

        final painter = tester
            .widget<CustomPaint>(
              find.descendant(
                  of: find.byType(AppStatusDot),
                  matching: find.byType(CustomPaint)),
            )
            .painter as AppStatusDotPainter;

        expect(painter.shape, AppStatusDot.shapeOf[status]);
      });
    }

    testWidgets('unknown draws nothing and names nothing', (tester) async {
      await _pump(tester, const AppStatusDot(status: AppPresence.unknown));

      expect(AppStatusDot.shapeOf.containsKey(AppPresence.unknown), isFalse);
      expect(
        find.descendant(
          of: find.byType(AppStatusDot),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
      expect(AppPresence.unknown.word, isNull);
    });

    testWidgets('hidden reuses the offline colour, distinguished only by shape',
        (tester) async {
      const tokens = AppTokens.light;
      await _pump(tester, const AppStatusDot(status: AppPresence.hidden),
          tokens: tokens);

      final painter = tester
          .widget<CustomPaint>(
            find.descendant(
                of: find.byType(AppStatusDot),
                matching: find.byType(CustomPaint)),
          )
          .painter as AppStatusDotPainter;

      expect(painter.color, tokens.status.offline);
      expect(painter.shape, isNot(AppStatusDot.shapeOf[AppPresence.offline]));
    });
  });

  group('AppBadge', () {
    testWidgets('role is outlined from the accent, uppercased, never filled',
        (tester) async {
      const tokens = AppTokens.light;
      await _pump(
          tester, const AppBadge(variant: AppBadgeVariant.role, label: 'admin'),
          tokens: tokens);

      expect(find.text('ADMIN'), findsOneWidget);
      final container = tester.widget<Container>(
        find.descendant(
            of: find.byType(AppBadge), matching: find.byType(Container)),
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, isNull, reason: 'role is outlined, not filled');
      expect((decoration.border as Border).top.color, tokens.accentFill);
      expect(
          tester.widget<Text>(find.text('ADMIN')).style!.color, tokens.accent);
    });

    testWidgets('tag is outlined with a hairline, colour-neutral, uppercased',
        (tester) async {
      const tokens = AppTokens.light;
      await _pump(
          tester, const AppBadge(variant: AppBadgeVariant.tag, label: 'bot'),
          tokens: tokens);

      expect(find.text('BOT'), findsOneWidget,
          reason: 'a tag is never colour-coded');
      expect(find.text('bot'), findsNothing);
      final container = tester.widget<Container>(
        find.descendant(
            of: find.byType(AppBadge), matching: find.byType(Container)),
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, isNull);
      expect((decoration.border as Border).top.color, tokens.borderSubtle);
      expect(tester.widget<Text>(find.text('BOT')).style!.color,
          tokens.textSecondary);
    });

    testWidgets('warn is outlined with the caution tokens, uppercased',
        (tester) async {
      const tokens = AppTokens.light;
      await _pump(
        tester,
        const AppBadge(variant: AppBadgeVariant.warn, label: 'expiring'),
        tokens: tokens,
      );

      expect(find.text('EXPIRING'), findsOneWidget);
      final container = tester.widget<Container>(
        find.descendant(
            of: find.byType(AppBadge), matching: find.byType(Container)),
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, isNull);
      expect((decoration.border as Border).top.color, tokens.warnText);
      expect(tester.widget<Text>(find.text('EXPIRING')).style!.color,
          tokens.warnText);
    });
  });

  group('AppIconButton', () {
    testWidgets('exposes its semantic label', (tester) async {
      await _pump(
        tester,
        AppIconButton(
            icon: AppIcons.settings,
            semanticLabel: 'Open settings',
            onPressed: () {}),
      );
      expect(find.bySemanticsLabel('Open settings'), findsOneWidget);
    });

    testWidgets('a null onPressed disables the control and blocks the tap',
        (tester) async {
      await _pump(
        tester,
        const AppIconButton(
            icon: AppIcons.settings, semanticLabel: 'Open settings'),
      );

      final semantics = tester.widget<Semantics>(
        find
            .descendant(
                of: find.byType(AppIconButton),
                matching: find.byType(Semantics))
            .first,
      );
      expect(semantics.properties.enabled, isFalse);

      // Must not throw: a disabled control's tap is simply a no-op.
      await tester.tap(find.byType(AppIconButton));
      await tester.pump();
    });

    testWidgets('a provided onPressed fires on tap', (tester) async {
      var pressed = false;
      await _pump(
        tester,
        AppIconButton(
          icon: AppIcons.settings,
          semanticLabel: 'Open settings',
          onPressed: () => pressed = true,
        ),
      );

      await tester.tap(find.byType(AppIconButton));
      await tester.pump();
      expect(pressed, isTrue);
    });

    testWidgets(
        'meets the touch hit-target floor when touch is set, pointer otherwise',
        (
      tester,
    ) async {
      await _pump(
        tester,
        AppIconButton(
            icon: AppIcons.settings,
            semanticLabel: 'x',
            onPressed: () {},
            touch: true),
      );
      expect(tester.getSize(find.byType(AppIconButton)),
          const Size.square(AppSizes.rowTouch));

      await _pump(
        tester,
        AppIconButton(
            icon: AppIcons.settings, semanticLabel: 'x', onPressed: () {}),
      );
      expect(tester.getSize(find.byType(AppIconButton)),
          const Size.square(AppSizes.rowPointer));
    });

    testWidgets('danger and ghost variants use distinguishable ink colours',
        (tester) async {
      const tokens = AppTokens.light;
      await _pump(
        tester,
        AppIconButton(
          icon: AppIcons.settings,
          semanticLabel: 'x',
          onPressed: () {},
          variant: AppIconButtonVariant.danger,
        ),
        tokens: tokens,
      );
      final dangerIcon = tester.widget<Icon>(find.byIcon(AppIcons.settings));
      expect(dangerIcon.color, tokens.dangerText);

      await _pump(
        tester,
        AppIconButton(
            icon: AppIcons.settings, semanticLabel: 'x', onPressed: () {}),
        tokens: tokens,
      );
      final ghostIcon = tester.widget<Icon>(find.byIcon(AppIcons.settings));
      expect(ghostIcon.color, tokens.textSecondary);
    });

    testWidgets(
      'focus draws its own ring, kept apart from the active state by shape rather '
      'than colour',
      (tester) async {
        const tokens = AppTokens.light;
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);

        // The focus *highlight*, unlike focus itself, is normally shown only
        // for keyboard interaction; force it on so requestFocus draws the ring.
        final previousStrategy = FocusManager.instance.highlightStrategy;
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        addTearDown(
            () => FocusManager.instance.highlightStrategy = previousStrategy);

        await _pump(
          tester,
          AppIconButton(
            icon: AppIcons.settings,
            semanticLabel: 'x',
            onPressed: () {},
            active: true,
            focusNode: focusNode,
          ),
          tokens: tokens,
        );

        final container = tester.widget<Container>(
          find.descendant(
              of: find.byType(AppIconButton), matching: find.byType(Container)),
        );
        // Active alone: a filled backdrop plus an accent border, no ring yet.
        expect(
            (container.decoration as BoxDecoration).color, tokens.accentSoft);
        expect(container.foregroundDecoration, isNull);

        focusNode.requestFocus();
        await tester.pump();

        final focusedContainer = tester.widget<Container>(
          find.descendant(
              of: find.byType(AppIconButton), matching: find.byType(Container)),
        );
        final ring = ((focusedContainer.foregroundDecoration as BoxDecoration)
                .border as Border)
            .top
            .color;
        expect(ring, tokens.focusRing);
        expect(
          (focusedContainer.decoration as BoxDecoration).color,
          tokens.accentSoft,
          reason: 'the active fill must still be present once focus is added',
        );
      },
    );
  });

  group('AppAvatar', () {
    testWidgets('falls back to a stripped, uppercased two-character initial',
        (tester) async {
      await _pump(tester, const AppAvatar(name: 'Ada Lovelace'));
      expect(find.text('AD'), findsOneWidget);
    });

    testWidgets('a single word still yields two characters, not one',
        (tester) async {
      await _pump(tester, const AppAvatar(name: 'Madonna'));
      expect(find.text('MA'), findsOneWidget);
    });

    testWidgets('never clips, so its edge stays anti-aliased under Impeller',
        (tester) async {
      await _pump(
        tester,
        AppAvatar(
          name: 'Ada Lovelace',
          image: MemoryImage(Uint8List(0)),
          status: AppPresence.online,
        ),
      );
      for (final clip in [ClipRRect, ClipOval, ClipPath, ClipRect]) {
        expect(
          find.descendant(
              of: find.byType(AppAvatar), matching: find.byType(clip)),
          findsNothing,
          reason: 'a stencil clip is not anti-aliased on desktop GL',
        );
      }
    });

    testWidgets('the tint hash matches the source design exactly',
        (tester) async {
      await _pump(tester, const AppAvatar(name: 'Ada Lovelace'));
      expect(
        _discOf(tester).color,
        const Color(0xFF5C6E7A),
        reason:
            'the same person must not change colour between screens that both use this hash',
      );
    });

    testWidgets('tintKey pins the tint to identity, not to the display string',
        (tester) async {
      Future<Color> tintOf(AppAvatar avatar) async {
        await _pump(tester, avatar);
        return _discOf(tester).color!;
      }

      final fullName = await tintOf(
          const AppAvatar(name: 'Ada Lovelace', tintKey: 'user-1'));
      final shortName =
          await tintOf(const AppAvatar(name: 'Ada', tintKey: 'user-1'));
      final renamed =
          await tintOf(const AppAvatar(name: 'Countess', tintKey: 'user-1'));
      expect(shortName, fullName,
          reason:
              'one person, one colour, whichever name form a surface shows');
      expect(renamed, fullName,
          reason: 'a display-name edit must not recolour the person');

      final other = await tintOf(
          const AppAvatar(name: 'Ada Lovelace', tintKey: 'user-2'));
      expect(other, isNot(fullName),
          reason:
              'a different identity behind the same name is a different person');
    });

    testWidgets('a square avatar never shows generated initials',
        (tester) async {
      await _pump(tester,
          const AppAvatar(name: 'Build Bot', shape: AppAvatarShape.square));
      expect(
        find.descendant(
            of: find.byType(AppAvatar), matching: find.byType(Text)),
        findsNothing,
        reason:
            'a bot avatar carries an icon, supplied by the caller, never a name hash',
      );
    });

    testWidgets('the size parameter is respected', (tester) async {
      await _pump(tester, const AppAvatar(name: 'Ada Lovelace', size: 80));
      expect(tester.getSize(find.byType(AppAvatar)), const Size.square(80));

      await _pump(tester, const AppAvatar(name: 'Ada Lovelace', size: 24));
      expect(tester.getSize(find.byType(AppAvatar)), const Size.square(24));
    });
  });
}

/// The initials disc: a supersampled shape rather than a clipped box, so
/// its edge is smooth under Impeller (see AppShapedImage).
({Color? color}) _discOf(WidgetTester tester) => (
      color: tester
          .widget<AppShapedDisc>(
            find.descendant(
                of: find.byType(AppAvatar),
                matching: find.byType(AppShapedDisc)),
          )
          .color,
    );
