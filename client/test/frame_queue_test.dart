import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yuanlian_client/src/net/frame_queue.dart';
import 'package:yuanlian_client/src/net/protocol.dart';

TileData _tile(int x, int y, {int width = 8, int height = 8, int bytes = 16}) {
  return TileData(
    x: x,
    y: y,
    width: width,
    height: height,
    jpeg: Uint8List(bytes)..[0] = 0xFF,
  );
}

FrameMessage _incremental(
  int seq, {
  int generation = 1,
  int width = 16,
  int height = 16,
  int tiles = 1,
  int bytesPerTile = 16,
}) {
  return FrameMessage(
    seq: seq,
    generation: generation,
    full: false,
    width: width,
    height: height,
    tiles: [
      for (var index = 0; index < tiles; index++)
        _tile(index * 8, 0, bytes: bytesPerTile),
    ],
  );
}

FrameMessage _full(int seq, {int generation = 1}) {
  return FrameMessage(
    seq: seq,
    generation: generation,
    full: true,
    width: 16,
    height: 16,
    tiles: [
      _tile(0, 0),
      _tile(8, 0),
      _tile(0, 8),
      _tile(8, 8),
    ],
  );
}

void main() {
  group('validateFrame', () {
    test('accepts a complete full frame', () {
      final validation = validateFrame(_full(1));
      expect(validation.error, isNull);
      expect(validation.pixels, 16 * 16);
    });

    test('rejects out-of-bounds and duplicate tiles', () {
      final outOfBounds = FrameMessage(
        seq: 1,
        generation: 1,
        full: false,
        width: 16,
        height: 16,
        tiles: [_tile(12, 0)],
      );
      expect(validateFrame(outOfBounds).error, contains('边界'));

      final duplicate = FrameMessage(
        seq: 1,
        generation: 1,
        full: false,
        width: 16,
        height: 16,
        tiles: [_tile(0, 0), _tile(0, 0)],
      );
      expect(validateFrame(duplicate).error, contains('重复'));
    });

    test('rejects incomplete full frames', () {
      final truncated = FrameMessage(
        seq: 1,
        generation: 1,
        full: true,
        width: 16,
        height: 16,
        tiles: [_tile(0, 0)],
      );
      expect(validateFrame(truncated).error, contains('覆盖'));
    });

    test('rejects absurd geometry and oversized tiles', () {
      final huge = FrameMessage(
        seq: 1,
        generation: 1,
        full: false,
        width: 16384,
        height: 16384,
        tiles: [_tile(0, 0)],
      );
      expect(validateFrame(huge).error, isNotNull);

      final bigTile = FrameMessage(
        seq: 1,
        generation: 1,
        full: false,
        width: 4096,
        height: 4096,
        tiles: [
          TileData(
            x: 0,
            y: 0,
            width: 2048,
            height: 2048,
            jpeg: Uint8List(16)..[0] = 1,
          ),
        ],
      );
      expect(validateFrame(bigTile).error, contains('图块像素'));
    });
  });

  group('FrameQueue', () {
    test('bounds the backlog and requests a full frame', () {
      final queue = FrameQueue(maxFrames: 2, maxBytes: 1024, maxPixels: 1024);
      expect(
        queue.offer(_incremental(1), validateFrame(_incremental(1)),
            currentGeneration: 1),
        isTrue,
      );
      expect(
        queue.offer(_incremental(2), validateFrame(_incremental(2)),
            currentGeneration: 1),
        isTrue,
      );
      expect(
        queue.offer(_incremental(3), validateFrame(_incremental(3)),
            currentGeneration: 1),
        isFalse,
      );
      expect(queue.length, 0);
      expect(queue.needsFull, isTrue);
      expect(queue.overflowCount, 1);

      // Incremental frames are refused until a full frame arrives.
      expect(
        queue.offer(_incremental(4), validateFrame(_incremental(4)),
            currentGeneration: 1),
        isFalse,
      );
      expect(
        queue.offer(_full(5), validateFrame(_full(5)), currentGeneration: 1),
        isTrue,
      );
      expect(queue.length, 1);
      queue.markFullApplied();
      expect(queue.needsFull, isFalse);
    });

    test('a newer full frame supersedes the backlog', () {
      final queue = FrameQueue(maxFrames: 4, maxBytes: 4096, maxPixels: 4096);
      queue.offer(_incremental(1), validateFrame(_incremental(1)),
          currentGeneration: 1);
      queue.offer(_incremental(2), validateFrame(_incremental(2)),
          currentGeneration: 1);
      expect(queue.length, 2);
      queue.offer(_full(3), validateFrame(_full(3)), currentGeneration: 1);
      expect(queue.length, 1);
      expect(queue.take()!.frame.full, isTrue);
    });

    test('rejects stale sequence numbers and partial new generations', () {
      final queue = FrameQueue();
      queue.offer(_incremental(10), validateFrame(_incremental(10)),
          currentGeneration: 1);
      expect(
        queue.offer(_incremental(9), validateFrame(_incremental(9)),
            currentGeneration: 1),
        isFalse,
      );
      final newGeneration = _incremental(11, generation: 2);
      expect(
        queue.offer(
          newGeneration,
          validateFrame(newGeneration),
          currentGeneration: 1,
        ),
        isFalse,
      );
      expect(queue.needsFull, isTrue);
      final full = _full(12, generation: 2);
      expect(
        queue.offer(full, validateFrame(full), currentGeneration: 1),
        isTrue,
      );
    });
  });
}
