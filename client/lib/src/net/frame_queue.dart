import 'protocol.dart';

/// Hard limits for one frame and for the decoded tile cache.
///
/// A full 8K UHD frame is 7680 x 4320 = 33.2 M pixels, so 36 M pixels keeps
/// real 8K screens working while rejecting absurd geometry. Decoded tiles are
/// capped at the same pixel budget (about 144 MiB at 4 bytes per pixel).
const int maxRemotePixels = 36 * 1024 * 1024;
const int maxRemoteEdge = 16384;
const int maxCachedTiles = 8192;
const int maxTilePixels = 1024 * 1024;
const int maxTileJpegBytes = 4 * 1024 * 1024;
const int maxQueuedFrames = 2;
const int maxQueuedBytes = 48 * 1024 * 1024;
const int maxQueuedPixels = maxRemotePixels;

class FrameValidation {
  const FrameValidation.error(this.error) : pixels = 0, bytes = 0;

  const FrameValidation.valid(this.pixels, this.bytes) : error = null;

  final String? error;
  final int pixels;
  final int bytes;

  bool get isValid => error == null;
}

/// Validates untrusted frame metadata before any JPEG is handed to the
/// decoder. It also checks that a full frame covers the whole screen, so a
/// truncated full frame cannot be mistaken for a successful first paint.
FrameValidation validateFrame(FrameMessage frame) {
  if (frame.width == 0 || frame.height == 0) {
    return const FrameValidation.error('画面尺寸为 0');
  }
  if (frame.width > maxRemoteEdge || frame.height > maxRemoteEdge) {
    return const FrameValidation.error('画面尺寸超过 16384 像素上限');
  }
  if (frame.width * frame.height > maxRemotePixels) {
    return const FrameValidation.error('画面像素数超过解码上限');
  }
  if (frame.tiles.isEmpty) {
    return const FrameValidation.error('画面帧没有图块');
  }
  if (frame.tiles.length > maxCachedTiles) {
    return const FrameValidation.error('图块数量超过上限');
  }
  final seen = <(int, int)>{};
  var pixels = 0;
  var bytes = 0;
  for (final tile in frame.tiles) {
    if (tile.width == 0 || tile.height == 0) {
      return const FrameValidation.error('图块尺寸为 0');
    }
    if (tile.width > frame.width ||
        tile.height > frame.height ||
        tile.x > frame.width - tile.width ||
        tile.y > frame.height - tile.height) {
      return const FrameValidation.error('图块超出画面边界');
    }
    if (tile.width * tile.height > maxTilePixels) {
      return const FrameValidation.error('单个图块像素数超过上限');
    }
    if (tile.jpeg.isEmpty) {
      return const FrameValidation.error('图块没有 JPEG 数据');
    }
    if (tile.jpeg.length > maxTileJpegBytes) {
      return const FrameValidation.error('单个图块 JPEG 超过 4 MiB');
    }
    if (!seen.add((tile.x, tile.y))) {
      return const FrameValidation.error('画面帧包含重复图块坐标');
    }
    pixels += tile.width * tile.height;
    bytes += tile.jpeg.length;
  }
  if (pixels > frame.width * frame.height) {
    return const FrameValidation.error('图块像素总数超过画面尺寸');
  }
  if (frame.full &&
      !frame.progressive &&
      pixels != frame.width * frame.height) {
    return const FrameValidation.error('全量帧未覆盖完整画面');
  }
  return FrameValidation.valid(pixels, bytes);
}

/// Bounded FIFO between the socket and the decoder.
///
/// Frames are never dropped silently while a decode is keeping up. On
/// overflow the backlog is discarded and a new full frame is requested,
/// because dropping arbitrary incremental frames would leave the viewer with a
/// permanently stale picture.
class FrameQueue {
  FrameQueue({
    this.maxFrames = maxQueuedFrames,
    this.maxBytes = maxQueuedBytes,
    this.maxPixels = maxQueuedPixels,
  });

  final int maxFrames;
  final int maxBytes;
  final int maxPixels;

  final List<FrameSlice> _pending = <FrameSlice>[];
  int _pendingBytes = 0;
  int _pendingPixels = 0;
  int lastQueuedSeq = -1;
  bool needsFull = false;
  int overflowCount = 0;

  int get length => _pending.length;
  int get pendingBytes => _pendingBytes;
  int get pendingPixels => _pendingPixels;

  /// Returns true when [frame] was queued. Stale frames and incremental frames
  /// arriving while a full refresh is required return false.
  bool offer(
    FrameMessage frame,
    FrameValidation validation, {
    required int currentGeneration,
  }) {
    if (!validation.isValid) {
      return false;
    }
    if (frame.seq <= lastQueuedSeq) {
      return false;
    }
    if (currentGeneration != -1 &&
        frame.generation != currentGeneration &&
        !frame.full) {
      needsFull = true;
      lastQueuedSeq = frame.seq;
      return false;
    }
    if (needsFull && !frame.full) {
      lastQueuedSeq = frame.seq;
      return false;
    }
    if (frame.full) {
      _clearPending();
    }
    final overflow =
        _pending.length >= maxFrames ||
        _pendingBytes + validation.bytes > maxBytes ||
        _pendingPixels + validation.pixels > maxPixels;
    if (overflow) {
      overflowCount += 1;
      _clearPending();
      if (!frame.full) {
        needsFull = true;
        lastQueuedSeq = frame.seq;
        return false;
      }
    }
    lastQueuedSeq = frame.seq;
    _pending.add(FrameSlice(frame, validation.bytes, validation.pixels));
    _pendingBytes += validation.bytes;
    _pendingPixels += validation.pixels;
    return true;
  }

  FrameSlice? take() {
    if (_pending.isEmpty) {
      return null;
    }
    final next = _pending.removeAt(0);
    _pendingBytes -= next.bytes;
    _pendingPixels -= next.pixels;
    return next;
  }

  void markFullApplied() {
    needsFull = false;
  }

  void clear({bool requireFull = false}) {
    _clearPending();
    needsFull = requireFull;
  }

  void _clearPending() {
    _pending.clear();
    _pendingBytes = 0;
    _pendingPixels = 0;
  }
}

class FrameSlice {
  const FrameSlice(this.frame, this.bytes, this.pixels);
  final FrameMessage frame;
  final int bytes;
  final int pixels;
}
