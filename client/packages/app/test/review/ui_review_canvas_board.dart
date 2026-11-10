// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The objects every canvas review board is seeded with, as the wire carries them.
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

Map<String, dynamic> _object(
  String id,
  String kind, {
  required Rect box,
  required Map<String, dynamic> props,
  required int seq,
  String author = 'me',
}) => {
  'id': id,
  'kind': kind,
  'z_index': seq,
  'x': box.left,
  'y': box.top,
  'w': box.width,
  'h': box.height,
  'props': props,
  'author_id': author,
  'seq': seq,
  'created_at': 0,
};

List<double> _wave(Rect box, {double turns = 3, double lift = 0.35}) => [
  for (var i = 0; i <= 40; i++) ...[
    box.width * i / 40,
    box.height / 2 + math.sin(i / 40 * turns * 2 * math.pi) * box.height * lift,
  ],
];

List<double> _loop(Rect box) => [
  for (var i = 0; i <= 48; i++) ...[
    box.width / 2 + math.cos(i / 48 * 2 * math.pi) * box.width / 2,
    box.height / 2 + math.sin(i / 48 * 2 * math.pi * 1.1) * box.height / 2,
  ],
];

Map<String, dynamic> reviewStroke(
  String id,
  Rect box, {
  String color = 'annotation',
  double width = 4,
  int seq = 1,
  String author = 'me',
  List<double>? points,
}) => _object(
  id,
  'stroke',
  box: box,
  props: {'points': points ?? _wave(box), 'width': width, 'color': color},
  seq: seq,
  author: author,
);

Map<String, dynamic> reviewShape(
  String id,
  Rect box,
  String shape, {
  int seq = 1,
  String author = 'me',
}) => _object(
  id,
  'shape',
  box: box,
  props: {'shape': shape},
  seq: seq,
  author: author,
);

Map<String, dynamic> reviewNote(
  String id,
  Rect box,
  String text, {
  int seq = 1,
  String author = 'me',
}) => _object(
  id,
  'note',
  box: box,
  props: {'text': text},
  seq: seq,
  author: author,
);

Map<String, dynamic> reviewText(
  String id,
  Rect box,
  String text, {
  String size = 'medium',
  String color = 'ink',
  int seq = 1,
  String author = 'me',
}) => _object(
  id,
  'text',
  box: box,
  props: {'text': text, 'size': size, 'color': color},
  seq: seq,
  author: author,
);

Map<String, dynamic> reviewImage(
  String id,
  Rect box, {
  int seq = 1,
  String author = 'user-ada',
}) => _object(
  id,
  'image',
  box: box,
  props: {'attachment': 'sha-$id', 'content_type': 'image/png'},
  seq: seq,
  author: author,
);

/// The id of the seeded photo, so a test can give it real pixels.
const reviewImageId = 'photo-1';

Rect _at(bool phone, Rect wide, Rect narrow) => phone ? narrow : wide;

/// A board with every kind of object on it; a portrait phone only frames the left of the shared area, so [phone] stacks it into that slice.
List<Map<String, dynamic>> populatedBoard({required bool phone}) => [
  reviewText(
    'title',
    _at(
      phone,
      const Rect.fromLTWH(140, 110, 760, 80),
      const Rect.fromLTWH(100, 80, 760, 80),
    ),
    'Sprint retro: what to keep',
    size: 'large',
    seq: 1,
  ),
  reviewStroke(
    'underline',
    _at(
      phone,
      const Rect.fromLTWH(140, 205, 640, 28),
      const Rect.fromLTWH(100, 175, 640, 28),
    ),
    width: 6,
    seq: 2,
    points: _wave(const Rect.fromLTWH(0, 0, 640, 28), turns: 4, lift: 0.3),
  ),
  reviewNote(
    'note-keep',
    _at(
      phone,
      const Rect.fromLTWH(140, 290, 300, 230),
      const Rect.fromLTWH(100, 270, 330, 250),
    ),
    'Keep: the follow chip, the shared view pill and the tile hide toggle',
    seq: 3,
  ),
  reviewNote(
    'note-drop',
    _at(
      phone,
      const Rect.fromLTWH(480, 290, 300, 230),
      const Rect.fromLTWH(470, 270, 330, 250),
    ),
    'Ask Ada whether the zoom pill still earns its corner',
    seq: 4,
    author: 'user-ada',
  ),
  reviewShape(
    'box',
    _at(
      phone,
      const Rect.fromLTWH(860, 270, 360, 240),
      const Rect.fromLTWH(850, 270, 300, 220),
    ),
    'rectangle',
    seq: 5,
  ),
  reviewShape(
    'oval',
    _at(
      phone,
      const Rect.fromLTWH(1290, 270, 330, 240),
      const Rect.fromLTWH(100, 590, 330, 220),
    ),
    'ellipse',
    seq: 6,
    author: 'user-bo',
  ),
  reviewShape(
    'arrow',
    _at(
      phone,
      const Rect.fromLTWH(1040, 540, 420, 130),
      const Rect.fromLTWH(480, 600, 420, 130),
    ),
    'arrow',
    seq: 7,
  ),
  reviewImage(
    reviewImageId,
    _at(
      phone,
      const Rect.fromLTWH(140, 580, 480, 320),
      const Rect.fromLTWH(100, 880, 480, 320),
    ),
    seq: 8,
  ),
  reviewStroke(
    'scribble-green',
    _at(
      phone,
      const Rect.fromLTWH(700, 700, 520, 200),
      const Rect.fromLTWH(640, 900, 520, 200),
    ),
    color: 'green',
    width: 5,
    seq: 9,
    author: 'user-bo',
  ),
  reviewStroke(
    'loop-purple',
    _at(
      phone,
      const Rect.fromLTWH(1330, 700, 260, 190),
      const Rect.fromLTWH(860, 1140, 260, 190),
    ),
    color: 'purple',
    width: 5,
    seq: 10,
    author: 'user-ada',
    points: _loop(const Rect.fromLTWH(0, 0, 260, 190)),
  ),
  reviewText(
    'caption',
    _at(
      phone,
      const Rect.fromLTWH(700, 930, 700, 56),
      const Rect.fromLTWH(100, 1280, 700, 56),
    ),
    'Round two: pick the winner on Friday',
    seq: 11,
  ),
];

/// A small board, enough ink to select and menu without the full spread.
List<Map<String, dynamic>> sparseBoard({required bool phone}) => [
  reviewNote(
    'note-solo',
    _at(
      phone,
      const Rect.fromLTWH(760, 360, 300, 220),
      const Rect.fromLTWH(560, 560, 330, 240),
    ),
    'Move the retro notes under the heading',
    seq: 1,
  ),
  reviewShape(
    'box-solo',
    _at(
      phone,
      const Rect.fromLTWH(1200, 360, 320, 220),
      const Rect.fromLTWH(560, 860, 330, 220),
    ),
    'rectangle',
    seq: 2,
  ),
  reviewImage(
    reviewImageId,
    _at(
      phone,
      const Rect.fromLTWH(300, 330, 360, 260),
      const Rect.fromLTWH(100, 300, 400, 280),
    ),
    seq: 3,
    author: 'me',
  ),
  reviewStroke(
    'scribble-solo',
    _at(
      phone,
      const Rect.fromLTWH(520, 700, 520, 160),
      const Rect.fromLTWH(100, 700, 400, 160),
    ),
    color: 'blue',
    seq: 4,
  ),
];
