import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/profile.dart';
import '../net/frame_queue.dart';
import '../net/protocol.dart';
import '../net/remote_client.dart';
import '../platform/keymap.dart';
import 'design_tokens.dart';
import 'file_browser_page.dart';
import 'widgets.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({
    super.key,
    required this.client,
    required this.profile,
    this.inputSelfTest = false,
    this.autoOpenFiles = false,
  });

  final RemoteClient client;
  final ConnectionProfile profile;
  final bool inputSelfTest;
  final bool autoOpenFiles;

  @override
  State<WorkspacePage> createState() => WorkspacePageState();
}

class WorkspacePageState extends State<WorkspacePage>
    with WidgetsBindingObserver {
  final Map<(int, int), ui.Image> _tiles = <(int, int), ui.Image>{};
  final FocusNode _focusNode = FocusNode(debugLabel: 'remote-workspace');
  late final StreamSubscription<RemoteEvent> _events;
  Timer? _statsTimer;

  int _remoteWidth = 0;
  int _remoteHeight = 0;
  int _generation = -1;
  int _lastAppliedSeq = -1;
  int _cachePixels = 0;
  bool _waitingFirstFrame = true;
  bool _hasFocus = true;
  bool _disposed = false;
  String? _disconnectReason;
  String? _frameFault;
  CursorMessage? _cursor;
  final FrameQueue _frameQueue = FrameQueue();
  bool _decoding = false;
  DateTime _lastKeyframeRequest = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastFrameFaultToast = DateTime.fromMillisecondsSinceEpoch(0);
  _Viewport _viewport = const _Viewport(Rect.zero, 1);
  int _buttonsMask = 0;
  bool _pointerInsideImage = false;
  (int, int)? _lastRemotePointer;
  double _scrollVertical = 0;
  double _scrollHorizontal = 0;

  File? _pointerDebugFile;

  bool _lifecycleSuspended = false;
  bool _controlMode = true;
  double _zoom = 1.0;
  Offset _pan = Offset.zero;
  Offset? _viewDragStart;
  Offset _viewPanStart = Offset.zero;
  Size _canvasSize = Size.zero;
  final Map<int, Offset> _pointers = <int, Offset>{};
  int? _primaryPointer;
  double _pinchStartDistance = 1;
  double _pinchStartZoom = 1;
  Offset _pinchStartFocal = Offset.zero;
  Offset _pinchStartPan = Offset.zero;

  int _presentedFrames = 0;
  int _lastFrames = 0;
  int _lastBytes = 0;
  DateTime _lastStatsAt = DateTime.now();
  double _fps = 0;
  double _mibps = 0;

  RemoteClient get _client => widget.client;

  /// Test-only entry point for the same validation path used by the socket.
  /// It does not bypass limits or inject fake product data.
  @visibleForTesting
  void debugHandleFrame(FrameMessage frame) => _onFrame(frame);

  @visibleForTesting
  bool get debugWaitingFirstFrame => _waitingFirstFrame;

  @visibleForTesting
  int get debugTileCount => _tiles.length;

  @visibleForTesting
  int get debugCachedPixels => _cachePixels;

  @visibleForTesting
  int get debugPendingFrames => _frameQueue.length;

  @visibleForTesting
  int get debugPresentedFrames => _presentedFrames;

  @visibleForTesting
  String? get debugFrameFault => _frameFault;

  @override
  void initState() {
    super.initState();
    _remoteWidth = _client.welcome?.screenWidth ?? 0;
    _remoteHeight = _client.welcome?.screenHeight ?? 0;
    _lastFrames = 0;
    _lastBytes = _client.bytesReceived;
    WidgetsBinding.instance.addObserver(this);
    _events = _client.events.listen(_onEvent);
    if (Platform.environment['YUANLIAN_DEBUG_INPUT'] == '1') {
      _pointerDebugFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}yuanlian-pointer.log',
      );
      _pointerDebugFile!.writeAsStringSync(
        'workspace initialised\n',
        mode: FileMode.write,
        flush: true,
      );
    }
    _client.requestKeyframe();
    _statsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickStats(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
    if (widget.inputSelfTest) {
      Timer(const Duration(seconds: 1), () {
        if (mounted) {
          _client.sendMouseMove(10, 10);
        }
      });
    }
    if (const bool.fromEnvironment('YUANLIAN_TEXT_SELF_TEST')) {
      Timer(const Duration(seconds: 8), () {
        if (mounted) {
          _client.sendText('远联 Unicode 😀 测试');
        }
      });
    }
    if (widget.autoOpenFiles) {
      Timer(const Duration(seconds: 1), () {
        if (mounted && _client.fileEnabled) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => FileBrowserPage(client: _client),
            ),
          );
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) {
      return;
    }
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _releaseAllInput();
        if (mounted && !_lifecycleSuspended) {
          setState(() => _lifecycleSuspended = true);
        }
      case AppLifecycleState.resumed:
        if (defaultTargetPlatform != TargetPlatform.android && mounted) {
          setState(() => _lifecycleSuspended = false);
        } else if (mounted) {
          setState(() => _lifecycleSuspended = true);
        }
    }
  }

  bool get _inputEnabled =>
      _client.inputAllowed &&
      !_lifecycleSuspended &&
      _controlMode &&
      _disconnectReason == null;

  Offset _clampPan(double zoom, Offset pan) {
    if (_remoteWidth <= 0 ||
        _remoteHeight <= 0 ||
        _canvasSize.width <= 0 ||
        _canvasSize.height <= 0) {
      return Offset.zero;
    }
    final base = math.min(
      _canvasSize.width / _remoteWidth,
      _canvasSize.height / _remoteHeight,
    );
    final scale = base * zoom;
    final imageWidth = _remoteWidth * scale;
    final imageHeight = _remoteHeight * scale;
    final maxX = math.max(0.0, (imageWidth - _canvasSize.width) / 2);
    final maxY = math.max(0.0, (imageHeight - _canvasSize.height) / 2);
    return Offset(pan.dx.clamp(-maxX, maxX), pan.dy.clamp(-maxY, maxY));
  }

  void _setZoom(double zoom) {
    final next = zoom.clamp(1.0, 4.0);
    setState(() {
      _zoom = next;
      _pan = _clampPan(next, _pan);
    });
  }

  void _resetView() {
    setState(() {
      _zoom = 1.0;
      _pan = Offset.zero;
    });
  }

  void _toggleControlMode() {
    if (_controlMode) {
      _releaseAllInput();
    }
    _pointers.clear();
    _primaryPointer = null;
    _viewDragStart = null;
    setState(() => _controlMode = !_controlMode);
    if (_controlMode) {
      _focusNode.requestFocus();
    }
  }

  void _beginPinch() {
    if (_pointers.length < 2) {
      return;
    }
    final points = _pointers.values.take(2).toList();
    _pinchStartDistance = (points[0] - points[1]).distance;
    if (_pinchStartDistance < 1) {
      _pinchStartDistance = 1;
    }
    _pinchStartZoom = _zoom;
    _pinchStartFocal = (points[0] + points[1]) / 2;
    _pinchStartPan = _pan;
    _viewDragStart = null;
  }

  void _updatePinch() {
    if (_pointers.length < 2) {
      return;
    }
    final points = _pointers.values.take(2).toList();
    final distance = (points[0] - points[1]).distance;
    final focal = (points[0] + points[1]) / 2;
    final nextZoom = (_pinchStartZoom * (distance / _pinchStartDistance)).clamp(
      1.0,
      4.0,
    );
    final nextPan = _pinchStartPan + (focal - _pinchStartFocal);
    setState(() {
      _zoom = nextZoom;
      _pan = _clampPan(nextZoom, nextPan);
    });
  }

  void _handleViewCommand(String command) {
    switch (command) {
      case 'toggle-control':
        _toggleControlMode();
      case 'zoom-in':
        _setZoom(_zoom + 0.5);
      case 'zoom-out':
        _setZoom(_zoom - 0.5);
      case 'fit':
        _resetView();
      case 'send-text':
        _showTextInputDialog();
    }
  }

  Future<void> _showTextInputDialog() async {
    if (!_client.inputAllowed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('Host 未授权输入，不能发送文本'),
          ),
        );
      }
      return;
    }
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('发送文本到远端'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 4,
            maxLength: 4096,
            decoration: const InputDecoration(
              hintText: '支持中文、emoji 与组合文本；通过 Host SendInput 注入。',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty || !mounted) {
      return;
    }
    _client.sendText(text);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('已发送 ${text.length} 个 UTF-16 单元到远端'),
      ),
    );
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    _statsTimer?.cancel();
    _events.cancel();
    _focusNode.dispose();
    _frameQueue.clear();
    for (final image in _tiles.values) {
      image.dispose();
    }
    _tiles.clear();
    _cachePixels = 0;
    _releaseAllInput();
    _client.disconnect();
    _client.dispose();
    super.dispose();
  }

  void _onEvent(RemoteEvent event) {
    if (_disposed) {
      return;
    }
    switch (event) {
      case FrameEvent(:final frame):
        _onFrame(frame);
      case CursorEvent(:final cursor):
        if (_cursor?.x != cursor.x ||
            _cursor?.y != cursor.y ||
            _cursor?.visible != cursor.visible) {
          setState(() => _cursor = cursor);
        }
      case HostErrorEvent(:final code, :final message):
        if (code == ErrorCode.inputDenied) {
          _client.sendReleaseAll();
          _buttonsMask = 0;
        }
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(
                code == ErrorCode.inputDenied
                    ? 'Host 拒绝输入，已切换为仅查看：$message'
                    : 'Host 报告错误 [$code]：$message',
              ),
            ),
          );
        }
      case DisconnectedEvent(:final reason):
        _buttonsMask = 0;
        _frameQueue.clear(requireFull: true);
        if (mounted) {
          setState(() => _disconnectReason = reason);
        }
      default:
        break;
    }
  }

  void _onFrame(FrameMessage frame) {
    if (_disposed || !mounted) {
      return;
    }
    final validation = validateFrame(frame);
    if (!validation.isValid) {
      _frameFault = validation.error;
      _frameQueue.needsFull = true;
      _requestFullFrame();
      return;
    }
    final queued = _frameQueue.offer(
      frame,
      validation,
      currentGeneration: _generation,
    );
    if (!queued) {
      if (_frameQueue.needsFull) {
        _requestFullFrame();
      }
      return;
    }
    if (!_decoding) {
      unawaited(_drainFrames());
    }
  }

  /// Requests a new full frame at most once every two seconds. The queue stays
  /// in "needs full" mode until a validated full frame has been applied, so
  /// incremental frames cannot paper over a corrupt or missing baseline.
  void _requestFullFrame() {
    _frameQueue.needsFull = true;
    if (mounted) {
      setState(() {});
    }
    final now = DateTime.now();
    if (now.difference(_lastKeyframeRequest) < const Duration(seconds: 2)) {
      return;
    }
    _lastKeyframeRequest = now;
    _client.requestKeyframe();
    if (_frameFault != null &&
        now.difference(_lastFrameFaultToast) >= const Duration(seconds: 5)) {
      _lastFrameFaultToast = now;
      debugPrint('frame rejected: $_frameFault');
    }
  }

  Future<void> _drainFrames() async {
    _decoding = true;
    try {
      while (!_disposed && mounted) {
        final slice = _frameQueue.take();
        if (slice == null) {
          break;
        }
        final applied = await _applyFrame(slice.frame);
        if (_disposed || !mounted) {
          return;
        }
        if (!applied) {
          _frameQueue.clear(requireFull: true);
          _requestFullFrame();
          break;
        }
        _presentedFrames += 1;
      }
    } finally {
      _decoding = false;
    }
  }

  Future<bool> _applyFrame(FrameMessage frame) async {
    if (_disposed || !mounted || frame.seq <= _lastAppliedSeq) {
      return false;
    }
    final newGeneration = frame.generation != _generation;
    if (newGeneration && !frame.full) {
      return false;
    }
    if ((frame.width != _remoteWidth || frame.height != _remoteHeight) &&
        !frame.full) {
      return false;
    }

    if (frame.full) {
      final decoded = <(TileData, ui.Image)>[];
      var decodedPixels = 0;
      for (final tile in frame.tiles) {
        final image = await _decodeTile(tile);
        if (image == null) {
          for (final (_, old) in decoded) {
            old.dispose();
          }
          return false;
        }
        decoded.add((tile, image));
        decodedPixels += image.width * image.height;
        if (decodedPixels > maxRemotePixels) {
          for (final (_, old) in decoded) {
            old.dispose();
          }
          return false;
        }
      }
      if (_disposed || !mounted) {
        for (final (_, old) in decoded) {
          old.dispose();
        }
        return false;
      }
      for (final image in _tiles.values) {
        image.dispose();
      }
      _tiles.clear();
      _cachePixels = 0;
      for (final (tile, image) in decoded) {
        _tiles[(tile.x, tile.y)] = image;
        _cachePixels += image.width * image.height;
      }
      _generation = frame.generation;
      _remoteWidth = frame.width;
      _remoteHeight = frame.height;
      _lastAppliedSeq = frame.seq;
      _frameQueue.markFullApplied();
      _frameFault = null;
      setState(() {
        _waitingFirstFrame = false;
      });
      return true;
    }

    for (final tile in frame.tiles) {
      final image = await _decodeTile(tile);
      if (image == null) {
        return false;
      }
      if (_disposed ||
          !mounted ||
          frame.generation != _generation ||
          frame.width != _remoteWidth ||
          frame.height != _remoteHeight) {
        image.dispose();
        return false;
      }
      final key = (tile.x, tile.y);
      final previous = _tiles[key];
      final nextPixels =
          _cachePixels -
          (previous == null ? 0 : previous.width * previous.height) +
          image.width * image.height;
      final nextCount = _tiles.length + (previous == null ? 1 : 0);
      if (nextCount > maxCachedTiles || nextPixels > maxRemotePixels) {
        image.dispose();
        return false;
      }
      _tiles[key] = image;
      previous?.dispose();
      _cachePixels = nextPixels;
    }
    _lastAppliedSeq = frame.seq;
    if (mounted) {
      setState(() {});
    }
    return true;
  }

  Future<ui.Image?> _decodeTile(TileData tile) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(tile.jpeg);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      // The descriptor now owns the buffer.
      buffer = null;
      if (descriptor.width != tile.width || descriptor.height != tile.height) {
        debugPrint(
          'tile JPEG is ${descriptor.width}x${descriptor.height}, '
          'declared ${tile.width}x${tile.height}; rejecting',
        );
        return null;
      }
      final codec = await descriptor.instantiateCodec(
        targetWidth: tile.width,
        targetHeight: tile.height,
      );
      try {
        final frameInfo = await codec.getNextFrame();
        final image = frameInfo.image;
        if (image.width != tile.width || image.height != tile.height) {
          image.dispose();
          return null;
        }
        return image;
      } finally {
        codec.dispose();
      }
    } on Object catch (error) {
      debugPrint('tile decode failed: $error');
      return null;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  void _tickStats() {
    if (!mounted) {
      return;
    }
    final now = DateTime.now();
    final seconds = now.difference(_lastStatsAt).inMilliseconds / 1000;
    if (seconds <= 0) {
      return;
    }
    final frames = _presentedFrames;
    final bytes = _client.bytesReceived;
    setState(() {
      _fps = (frames - _lastFrames) / seconds;
      _mibps = (bytes - _lastBytes) / 1048576 / seconds;
      _lastFrames = frames;
      _lastBytes = bytes;
      _lastStatsAt = now;
    });
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!_inputEnabled) {
      return KeyEventResult.ignored;
    }
    final binding = vkFor(event.logicalKey);
    if (binding == null) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _client.sendKey(binding.vk, true, binding.extended);
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _client.sendKey(binding.vk, false, binding.extended);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onFocusChange(bool focused) {
    _hasFocus = focused;
    if (!focused) {
      _releaseAllInput();
    }
  }

  void _debugPointer(String message) {
    _pointerDebugFile?.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  void _updateMouse(Offset localPosition) {
    _debugPointer(
      'hover/move local=$localPosition viewport=${_viewport.imageRect} '
      'scale=${_viewport.scale} allowed=$_inputEnabled',
    );
    if (!_inputEnabled || _viewport.scale <= 0) {
      return;
    }
    final rect = _viewport.imageRect;
    if (!rect.contains(localPosition)) {
      _pointerInsideImage = false;
      _releaseButtons();
      _lastRemotePointer = null;
      return;
    }
    _pointerInsideImage = true;
    final x = ((localPosition.dx - rect.left) / _viewport.scale).floor().clamp(
      0,
      _remoteWidth - 1,
    );
    final y = ((localPosition.dy - rect.top) / _viewport.scale).floor().clamp(
      0,
      _remoteHeight - 1,
    );
    if (_lastRemotePointer == (x, y)) {
      return;
    }
    _lastRemotePointer = (x, y);
    _client.sendMouseMove(x, y);
  }

  void _onPointerDown(PointerDownEvent event) {
    _debugPointer('down buttons=${event.buttons} local=${event.localPosition}');
    _pointers[event.pointer] = event.localPosition;
    if (!_controlMode) {
      if (_pointers.length == 1) {
        _viewDragStart = event.localPosition;
        _viewPanStart = _pan;
      } else if (_pointers.length == 2) {
        _beginPinch();
      }
      return;
    }
    if (_primaryPointer != null && _primaryPointer != event.pointer) {
      return;
    }
    _primaryPointer = event.pointer;
    _focusNode.requestFocus();
    _updateMouse(event.localPosition);
    _syncButtons(event.buttons);
  }

  void _onPointerHover(PointerHoverEvent event) {
    if (!_controlMode) {
      return;
    }
    _debugPointer(
      'hover buttons=${event.buttons} local=${event.localPosition}',
    );
    _updateMouse(event.localPosition);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_pointers.containsKey(event.pointer)) {
      _pointers[event.pointer] = event.localPosition;
    }
    if (!_controlMode) {
      if (_pointers.length >= 2) {
        _updatePinch();
        return;
      }
      final start = _viewDragStart;
      if (start != null) {
        final next = _viewPanStart + (event.localPosition - start);
        setState(() => _pan = _clampPan(_zoom, next));
      }
      return;
    }
    if (_primaryPointer != event.pointer) {
      return;
    }
    _updateMouse(event.localPosition);
    _syncButtons(event.buttons);
  }

  void _onPointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (!_controlMode) {
      if (_pointers.length == 1) {
        _viewDragStart = _pointers.values.first;
        _viewPanStart = _pan;
      } else if (_pointers.isEmpty) {
        _viewDragStart = null;
      }
      return;
    }
    if (_primaryPointer == event.pointer) {
      _primaryPointer = null;
      _syncButtons(event.buttons);
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    _viewDragStart = null;
    if (_primaryPointer == event.pointer) {
      _primaryPointer = null;
      _releaseButtons();
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }
    if (!_controlMode) {
      _setZoom(_zoom + (event.scrollDelta.dy < 0 ? 0.25 : -0.25));
      return;
    }
    if (!_inputEnabled || !_viewport.imageRect.contains(event.localPosition)) {
      return;
    }
    _scrollVertical += -event.scrollDelta.dy;
    _scrollHorizontal += event.scrollDelta.dx;
    final vertical = (_scrollVertical / 60).truncate();
    final horizontal = (_scrollHorizontal / 60).truncate();
    if (vertical != 0) {
      _scrollVertical -= vertical * 60;
      _client.sendWheel(vertical * 120, 0);
    }
    if (horizontal != 0) {
      _scrollHorizontal -= horizontal * 60;
      _client.sendWheel(0, horizontal * 120);
    }
  }

  void _syncButtons(int nextMask) {
    _debugPointer('buttons next=$nextMask inside=$_pointerInsideImage');
    if (!_inputEnabled || !_pointerInsideImage) {
      _releaseButtons();
      return;
    }
    final changedDown = nextMask & ~_buttonsMask;
    final changedUp = _buttonsMask & ~nextMask;
    const mapping = <int, HostMouseButton>{
      kPrimaryMouseButton: HostMouseButton.left,
      kSecondaryMouseButton: HostMouseButton.right,
      kMiddleMouseButton: HostMouseButton.middle,
      kBackMouseButton: HostMouseButton.back,
      kForwardMouseButton: HostMouseButton.forward,
    };
    for (final entry in mapping.entries) {
      if (changedDown & entry.key != 0) {
        _client.sendMouseButton(entry.value, true);
      }
      if (changedUp & entry.key != 0) {
        _client.sendMouseButton(entry.value, false);
      }
    }
    _buttonsMask = nextMask;
  }

  void _releaseButtons() {
    if (_buttonsMask == 0) {
      return;
    }
    const mapping = <int, HostMouseButton>{
      kPrimaryMouseButton: HostMouseButton.left,
      kSecondaryMouseButton: HostMouseButton.right,
      kMiddleMouseButton: HostMouseButton.middle,
      kBackMouseButton: HostMouseButton.back,
      kForwardMouseButton: HostMouseButton.forward,
    };
    for (final entry in mapping.entries) {
      if (_buttonsMask & entry.key != 0) {
        _client.sendMouseButton(entry.value, false);
      }
    }
    _buttonsMask = 0;
  }

  void _releaseAllInput() {
    _client.sendReleaseAll();
    _buttonsMask = 0;
    _lastRemotePointer = null;
  }

  Future<void> _leave() async {
    if (_disconnectReason == null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('断开远程会话'),
          content: Text('断开与 ${widget.profile.name} 的当前会话？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('断开'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
    }
    _client.disconnect();
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  void _showDetails() {
    final welcome = _client.welcome;
    if (welcome == null) {
      return;
    }
    final fingerprint = widget.profile.fingerprint
        .replaceAll(':', '')
        .toUpperCase();
    final rows = <(String, String)>[
      ('Host', welcome.hostName),
      ('Host ID', welcome.hostId),
      ('地址', widget.profile.address),
      ('屏幕', '${welcome.screenWidth} × ${welcome.screenHeight}'),
      ('模式', welcome.mode == 'flow' ? '流畅 · 渐进图块（空白区域待刷新）' : welcome.mode),
      ('图块', '${welcome.tileSize} px'),
      ('协议', 'v${welcome.protocolVersion} · ALPN yuanlian/1'),
      (
        '授权',
        welcome.authenticated
            ? '账号 ${welcome.account} · ${welcome.authMode}'
            : '匿名开发模式 · ${welcome.authMode}',
      ),
      ('权限', permissionSummary(welcome.permissions)),
      (
        '票据到期',
        welcome.ticketExpiresAt == 0
            ? '无票据（开发直连）'
            : DateTime.fromMillisecondsSinceEpoch(
                welcome.ticketExpiresAt * 1000,
              ).toLocal().toString(),
      ),
      ('输入', _client.inputAllowed ? '已授权' : '仅查看'),
      (
        'TLS 指纹',
        fingerprint.length >= 16
            ? '${fingerprint.substring(0, 16)}…'
            : fingerprint,
      ),
      ('画面代际', '$_generation'),
      ('累计帧', '${_client.framesReceived}'),
      ('累计数据', '${(_client.bytesReceived / 1048576).toStringAsFixed(2)} MiB'),
      ('RTT', '${_client.rttMs} ms'),
    ];
    final diagnostics = rows.map((row) => '${row.$1}: ${row.$2}').join('\n');
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('会话详情'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final row in rows) InfoRow(label: row.$1, value: row.$2),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => copyText(context, diagnostics, label: '已复制脱敏会话信息'),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: YlRemoteColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildToolbar(theme),
            if (_lifecycleSuspended && _client.inputAllowed)
              _buildSuspendedBanner(),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _canvasSize = constraints.biggest;
                  _viewport = _Viewport.forSize(
                    constraints.biggest,
                    _remoteWidth,
                    _remoteHeight,
                    zoom: _zoom,
                    pan: _pan,
                  );
                  return Focus(
                    focusNode: _focusNode,
                    autofocus: true,
                    onKeyEvent: _handleKey,
                    onFocusChange: _onFocusChange,
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _onPointerDown,
                      onPointerHover: _onPointerHover,
                      onPointerMove: _onPointerMove,
                      onPointerUp: _onPointerUp,
                      onPointerCancel: _onPointerCancel,
                      onPointerSignal: _onPointerSignal,
                      child: MouseRegion(
                        cursor: !_controlMode
                            ? SystemMouseCursors.grab
                            : _inputEnabled && _hasFocus
                            ? SystemMouseCursors.none
                            : SystemMouseCursors.basic,
                        onExit: (_) {
                          _releaseButtons();
                          _lastRemotePointer = null;
                        },
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            RepaintBoundary(
                              child: CustomPaint(
                                painter: _RemotePainter(
                                  tiles: _tiles,
                                  viewport: _viewport,
                                  cursor: _cursor,
                                  showCursor: _remoteWidth > 0,
                                ),
                              ),
                            ),
                            if (_waitingFirstFrame && _disconnectReason == null)
                              _WaitingOverlay(message: _frameFault),
                            if (_disconnectReason != null)
                              _DisconnectedOverlay(
                                reason: _disconnectReason!,
                                onBack: () =>
                                    Navigator.of(context)
                                        .popUntil((route) => route.isFirst),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            _buildStatusBar(theme),
          ],
        ),
      ),
    );
  }

  List<PopupMenuEntry<String>> _viewMenuItems() {
    return [
      PopupMenuItem(
        value: 'toggle-control',
        child: Row(
          children: [
            Icon(
              _controlMode ? Icons.visibility_outlined : Icons.mouse_rounded,
              size: 18,
            ),
            const SizedBox(width: 10),
            Text(_controlMode ? '切换到查看模式' : '恢复控制'),
          ],
        ),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: 'zoom-in',
        child: Row(
          children: [
            Icon(Icons.zoom_in_rounded, size: 18),
            SizedBox(width: 10),
            Text('放大'),
          ],
        ),
      ),
      const PopupMenuItem(
        value: 'zoom-out',
        child: Row(
          children: [
            Icon(Icons.zoom_out_rounded, size: 18),
            SizedBox(width: 10),
            Text('缩小'),
          ],
        ),
      ),
      const PopupMenuItem(
        value: 'fit',
        child: Row(
          children: [
            Icon(Icons.fit_screen_rounded, size: 18),
            SizedBox(width: 10),
            Text('适应窗口'),
          ],
        ),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: 'send-text',
        enabled: _client.inputAllowed,
        child: Row(
          children: [
            const Icon(Icons.keyboard_alt_outlined, size: 18),
            const SizedBox(width: 10),
            Text(_client.inputAllowed ? '发送文本…' : '发送文本（无输入权限）'),
          ],
        ),
      ),
    ];
  }

  Widget _buildSuspendedBanner() {
    return Container(
      color: YlRemoteColors.bannerSurface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(
            Icons.pause_circle_outline_rounded,
            size: 16,
            color: YlRemoteColors.viewOnly,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '应用进入后台，远程控制已暂停；恢复后默认处于查看模式。',
              style: TextStyle(color: YlRemoteColors.bannerText, fontSize: 12),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 36),
              foregroundColor: YlRemoteColors.viewOnly,
            ),
            onPressed: () {
              setState(() => _lifecycleSuspended = false);
              _focusNode.requestFocus();
            },
            child: const Text('恢复控制'),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(ThemeData theme) {
    final welcome = _client.welcome;
    final compact = MediaQuery.sizeOf(context).width < 800;
    if (compact) {
      return Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: const BoxDecoration(
          color: YlRemoteColors.chrome,
          border: Border(
            bottom: BorderSide(color: YlRemoteColors.chromeOutline),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: '断开并返回',
              onPressed: _leave,
              icon: const Icon(
                Icons.arrow_back_rounded,
                color: YlRemoteColors.textSecondary,
              ),
            ),
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: YlRemoteColors.accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.desktop_windows_rounded,
                size: 17,
                color: YlRemoteColors.accentIcon,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                welcome?.hostName ?? widget.profile.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: YlRemoteColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _DarkPill(
              label: !_controlMode
                  ? '查看模式'
                  : _inputEnabled
                  ? '可控制'
                  : _lifecycleSuspended
                  ? '已暂停'
                  : '仅查看',
              icon: !_controlMode
                  ? Icons.visibility_outlined
                  : _inputEnabled
                  ? Icons.mouse_rounded
                  : Icons.visibility_outlined,
              color: !_controlMode
                  ? YlRemoteColors.viewing
                  : _inputEnabled
                  ? YlRemoteColors.connected
                  : YlRemoteColors.viewOnly,
              onTap: _toggleControlMode,
            ),
            Tooltip(
              message: _zoom > 1.01 ? '缩放到适应' : '放大到 200%',
              child: IconButton(
                onPressed: () => _setZoom(_zoom > 1.01 ? 1.0 : 2.0),
                icon: Icon(
                  _zoom > 1.01 ? Icons.zoom_out_rounded : Icons.zoom_in_rounded,
                  color: YlRemoteColors.textSecondary,
                ),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '会话操作',
              color: YlRemoteColors.chromeRaised,
              icon: const Icon(
                Icons.more_vert_rounded,
                color: YlRemoteColors.textSecondary,
              ),
              onSelected: (value) {
                if (value == 'toggle-control' ||
                    value == 'zoom-in' ||
                    value == 'zoom-out' ||
                    value == 'fit' ||
                    value == 'send-text') {
                  _handleViewCommand(value);
                  return;
                }
                switch (value) {
                  case 'keyframe':
                    _client.requestKeyframe();
                  case 'details':
                    _showDetails();
                  case 'files':
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => FileBrowserPage(client: _client),
                      ),
                    );
                  case 'disconnect':
                    _leave();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'keyframe',
                  child: Row(
                    children: [
                      Icon(Icons.refresh_rounded, size: 18),
                      SizedBox(width: 10),
                      Text('请求全量帧'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'details',
                  child: Row(
                    children: [
                      Icon(Icons.info_outline_rounded, size: 18),
                      SizedBox(width: 10),
                      Text('会话详情'),
                    ],
                  ),
                ),
                ..._viewMenuItems(),
                PopupMenuItem(
                  value: 'files',
                  enabled: _client.fileEnabled,
                  child: Row(
                    children: [
                      const Icon(Icons.folder_outlined, size: 18),
                      const SizedBox(width: 10),
                      Text(_client.fileEnabled ? '文件传输' : '文件传输（Host 未授权）'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'disconnect',
                  child: Row(
                    children: [
                      Icon(Icons.link_off_rounded, size: 18),
                      SizedBox(width: 10),
                      Text('断开'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: YlRemoteColors.chrome,
        border: Border(bottom: BorderSide(color: YlRemoteColors.chromeOutline)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '断开并返回',
            onPressed: _leave,
            icon: const Icon(
              Icons.arrow_back_rounded,
              color: YlRemoteColors.textSecondary,
            ),
          ),
          const SizedBox(width: 4),
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: YlRemoteColors.accent.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.desktop_windows_rounded,
              size: 17,
              color: YlRemoteColors.accentIcon,
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                welcome?.hostName ?? widget.profile.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: YlRemoteColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                widget.profile.address,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: YlRemoteColors.textTertiary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(width: 16),
          const _DarkPill(label: '图块模式', icon: Icons.grid_view_rounded),
          const SizedBox(width: 8),
          _DarkPill(
            label: !_controlMode
                ? '查看模式'
                : _inputEnabled
                ? '可控制'
                : _lifecycleSuspended
                ? '已暂停'
                : '仅查看',
            icon: _client.inputAllowed
                ? Icons.mouse_rounded
                : Icons.visibility_outlined,
            color: !_controlMode
                ? YlRemoteColors.viewing
                : _inputEnabled
                ? YlRemoteColors.connected
                : YlRemoteColors.viewOnly,
            onTap: _toggleControlMode,
          ),
          const Spacer(),
          PopupMenuButton<String>(
            tooltip: '显示与控制',
            color: YlRemoteColors.chromeRaised,
            icon: const Icon(
              Icons.aspect_ratio_rounded,
              color: YlRemoteColors.textSecondary,
            ),
            onSelected: _handleViewCommand,
            itemBuilder: (context) => _viewMenuItems(),
          ),
          Tooltip(
            message: '请求 Host 发送全量帧',
            child: IconButton(
              onPressed: _client.requestKeyframe,
              icon: const Icon(
                Icons.refresh_rounded,
                color: YlRemoteColors.textSecondary,
              ),
            ),
          ),
          Tooltip(
            message: _client.fileEnabled
                ? '文件传输（授权目录：${_client.fileRootLabel}）'
                : 'Host 未配置 --file-root，文件访问未启用',
            child: IconButton(
              onPressed: _client.fileEnabled
                  ? () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => FileBrowserPage(client: _client),
                        ),
                      );
                    }
                  : null,
              icon: Icon(
                Icons.folder_outlined,
                color: _client.fileEnabled
                    ? YlRemoteColors.textSecondary
                    : YlRemoteColors.iconDisabled,
              ),
            ),
          ),
          Tooltip(
            message: '会话详情与诊断',
            child: IconButton(
              onPressed: _showDetails,
              icon: const Icon(
                Icons.info_outline_rounded,
                color: YlRemoteColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 6),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              backgroundColor: YlRemoteColors.dangerSurface,
              foregroundColor: YlRemoteColors.dangerText,
              minimumSize: const Size(0, 36),
            ),
            onPressed: _leave,
            icon: const Icon(Icons.link_off_rounded, size: 17),
            label: const Text('断开'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(ThemeData theme) {
    final mono = theme.textTheme.bodySmall?.copyWith(
      color: YlRemoteColors.textTertiary,
      fontFamily: 'Consolas',
      fontSize: 11.5,
    );
    final state = _disconnectReason != null
        ? '连接中断'
        : _waitingFirstFrame
        ? '等待首帧'
        : '实时画面';
    final compact = MediaQuery.sizeOf(context).width < 800;
    if (compact) {
      return Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: const BoxDecoration(
          color: YlRemoteColors.statusBar,
          border: Border(top: BorderSide(color: YlRemoteColors.statusOutline)),
        ),
        child: Row(
          children: [
            Icon(
              _disconnectReason != null
                  ? Icons.error_outline_rounded
                  : Icons.monitor_rounded,
              size: 13,
              color: _disconnectReason != null
                  ? YlRemoteColors.danger
                  : YlRemoteColors.connected,
            ),
            const SizedBox(width: 5),
            Text(state, style: mono),
            const SizedBox(width: 10),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Text('$_remoteWidth×$_remoteHeight', style: mono),
                    const SizedBox(width: 10),
                    Text('${(_zoom * 100).round()}%', style: mono),
                    const SizedBox(width: 10),
                    Text('${_fps.toStringAsFixed(1)} fps', style: mono),
                    const SizedBox(width: 10),
                    Text('RTT ${_client.rttMs} ms', style: mono),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        color: YlRemoteColors.statusBar,
        border: Border(top: BorderSide(color: YlRemoteColors.statusOutline)),
      ),
      child: Row(
        children: [
          Icon(
            _disconnectReason != null
                ? Icons.error_outline_rounded
                : Icons.monitor_rounded,
            size: 13,
            color: _disconnectReason != null
                ? YlRemoteColors.danger
                : YlRemoteColors.connected,
          ),
          const SizedBox(width: 6),
          Text(state, style: mono),
          const SizedBox(width: 16),
          Text('$_remoteWidth × $_remoteHeight', style: mono),
          const SizedBox(width: 16),
          Text('${_fps.toStringAsFixed(1)} fps', style: mono),
          const SizedBox(width: 16),
          Text('${_mibps.toStringAsFixed(2)} MiB/s', style: mono),
          const SizedBox(width: 16),
          Text('RTT ${_client.rttMs} ms', style: mono),
          const Spacer(),
          const Icon(
            Icons.lock_outline_rounded,
            size: 12,
            color: YlRemoteColors.textDisabled,
          ),
          const SizedBox(width: 5),
          Text('TLS 已固定 · 直连', style: mono),
        ],
      ),
    );
  }
}

class _Viewport {
  const _Viewport(this.imageRect, this.scale);
  final Rect imageRect;
  final double scale;

  factory _Viewport.forSize(
    Size size,
    int remoteWidth,
    int remoteHeight, {
    double zoom = 1.0,
    Offset pan = Offset.zero,
  }) {
    if (remoteWidth <= 0 ||
        remoteHeight <= 0 ||
        size.width <= 0 ||
        size.height <= 0) {
      return const _Viewport(Rect.zero, 1);
    }
    final base = math.min(size.width / remoteWidth, size.height / remoteHeight);
    final scale = base * zoom;
    final width = remoteWidth * scale;
    final height = remoteHeight * scale;
    return _Viewport(
      Rect.fromLTWH(
        (size.width - width) / 2 + pan.dx,
        (size.height - height) / 2 + pan.dy,
        width,
        height,
      ),
      scale,
    );
  }
}

class _RemotePainter extends CustomPainter {
  _RemotePainter({
    required this.tiles,
    required this.viewport,
    required this.cursor,
    required this.showCursor,
  });

  final Map<(int, int), ui.Image> tiles;
  final _Viewport viewport;
  final CursorMessage? cursor;
  final bool showCursor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = YlRemoteColors.background,
    );
    final rect = viewport.imageRect;
    if (rect.isEmpty) {
      return;
    }
    final paint = Paint()..filterQuality = FilterQuality.medium;
    for (final entry in tiles.entries) {
      final image = entry.value;
      final x = entry.key.$1.toDouble();
      final y = entry.key.$2.toDouble();
      final dest = Rect.fromLTWH(
        rect.left + x * viewport.scale,
        rect.top + y * viewport.scale,
        image.width * viewport.scale,
        image.height * viewport.scale,
      );
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        dest,
        paint,
      );
    }
    canvas.drawRect(
      rect.deflate(0.5),
      Paint()
        ..color = YlRemoteColors.frameOutline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final currentCursor = cursor;
    if (showCursor && currentCursor != null && currentCursor.visible) {
      final x = rect.left + currentCursor.x * viewport.scale;
      final y = rect.top + currentCursor.y * viewport.scale;
      if (rect.contains(Offset(x, y))) {
        final path = Path()
          ..moveTo(x, y)
          ..lineTo(x, y + 15)
          ..lineTo(x + 4.5, y + 11.5)
          ..lineTo(x + 7.5, y + 18)
          ..lineTo(x + 10, y + 17)
          ..lineTo(x + 7, y + 10.5)
          ..lineTo(x + 12, y + 10.5)
          ..close();
        canvas.drawPath(
          path,
          Paint()
            ..color = YlRemoteColors.cursorOutline
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.6
            ..strokeJoin = StrokeJoin.round,
        );
        canvas.drawPath(path, Paint()..color = YlRemoteColors.textPrimary);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RemotePainter oldDelegate) => true;
}

class _WaitingOverlay extends StatelessWidget {
  const _WaitingOverlay({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: YlRemoteColors.overlay,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          decoration: BoxDecoration(
            color: YlRemoteColors.panel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: YlRemoteColors.panelOutline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 14),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '等待首帧',
                      style: TextStyle(
                        color: YlRemoteColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      message == null
                          ? '正在等待 Host 采集与编码首幅画面'
                          : '首帧未通过校验（$message），正在请求完整刷新',
                      style: const TextStyle(
                        color: YlRemoteColors.textTertiary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DisconnectedOverlay extends StatelessWidget {
  const _DisconnectedOverlay({required this.reason, required this.onBack});
  final String reason;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: YlRemoteColors.overlayStrong,
      child: Center(
        child: Container(
          width: 420,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: YlRemoteColors.panel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: YlRemoteColors.dangerOutline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.link_off_rounded, color: YlRemoteColors.danger),
                  SizedBox(width: 8),
                  Text(
                    '连接中断',
                    style: TextStyle(
                      color: YlRemoteColors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                reason,
                style: const TextStyle(
                  color: YlRemoteColors.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: onBack,
                  child: const Text('返回首页'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DarkPill extends StatelessWidget {
  const _DarkPill({
    required this.label,
    required this.icon,
    this.color = YlRemoteColors.textSecondary,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: YlRemoteColors.chromeRaised,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: YlRemoteColors.panelOutline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) {
      return content;
    }
    return Tooltip(
      message: '切换查看/控制模式',
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(cursor: SystemMouseCursors.click, child: content),
      ),
    );
  }
}
