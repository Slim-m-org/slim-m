// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Scenes shaped like what the shipped modules emit, for geometry tests.
library;

Map<String, Object?> sceneOf(double w, double h, List<Object> ops) => {
  r'$slim': 'scene/1',
  'width': w,
  'height': h,
  'background': 'surface',
  'ops': ops,
  'status': 'status',
  'controls': ['reset'],
};

Map<String, Object?> wordGuessScene() => sceneOf(100, 100, [
  for (var row = 0; row < 6; row++)
    for (var col = 0; col < 5; col++)
      {
        'op': 'rect',
        'x': 21.0 + col * 12,
        'y': 4.0 + row * 12,
        'w': 10,
        'h': 10,
        'r': 1.5,
        'fill': 'sunken',
        'stroke': 'border',
        'sw': 0.3,
      },
  {'op': 'input', 'x': 21, 'y': 80, 'w': 58, 'submit': 'guess', 'max': 5},
]);

Map<String, Object?> gridScene(double size, int n) => sceneOf(size, size, [
  for (var i = 0; i < n * n; i++)
    {
      'op': 'rect',
      'x': (i % n) * size / n,
      'y': (i ~/ n) * size / n,
      'w': size / n,
      'h': size / n,
      'fill': 'sunken',
      'stroke': 'border',
      'sw': 0.5,
    },
]);

Map<String, Object?> lifeScene() => sceneOf(48, 48, [
  {
    'op': 'cells',
    'cols': 48,
    'rows': 48,
    'data': '0' * (48 * 48),
    'palette': ['sunken', 'accent'],
  },
]);

Map<String, Object?> spirographScene() => sceneOf(100, 100, [
  {'op': 'path', 'd': 'M20 30 L80 30 L80 70 L20 70 Z', 'stroke': 'accent'},
]);

Map<String, Object?> plotScene() => sceneOf(100, 64, [
  {
    'op': 'line',
    'x1': 4,
    'y1': 40,
    'x2': 96,
    'y2': 40,
    'stroke': 'border',
    'sw': 0.5,
  },
  for (var i = 0; i < 5; i++) ...[
    {
      'op': 'rect',
      'x': 8.0 + i * 17,
      'y': 40.0 - (i + 1) * 5,
      'w': 11,
      'h': (i + 1) * 5.0,
      'fill': 'accent',
    },
    {
      'op': 'text',
      'x': 13.5 + i * 17,
      'y': 45,
      's': 'item$i',
      'size': 4,
      'align': 'center',
    },
  ],
]);

final shippedScenes = <String, Map<String, Object?>>{
  'word-guess': wordGuessScene(),
  'minesweeper': gridScene(264, 12),
  'connect-four': gridScene(70, 7),
  'tic-tac-toe': gridScene(90, 3),
  'game-of-life': lifeScene(),
  'spirograph': spirographScene(),
  'plot': plotScene(),
};
