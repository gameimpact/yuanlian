import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/profile.dart';
import 'bincode.dart';
import 'protocol.dart';

enum RemotePhase {
  idle,
  resolving,
  connecting,
  securing,
  waitingWelcome,
  waitingFirstFrame,
  ready,
  failed,
  disconnected;

  String get label => switch (this) {
    RemotePhase.idle => '未连接',
    RemotePhase.resolving => '解析地址',
    RemotePhase.connecting => '建立 TCP 连接',
    RemotePhase.securing => 'TLS 握手与指纹校验',
    RemotePhase.waitingWelcome => '等待 Host 授权',
    RemotePhase.waitingFirstFrame => '等待首帧',
    RemotePhase.ready => '已连接',
    RemotePhase.failed => '连接失败',
    RemotePhase.disconnected => '已断开',
  };

  bool get active =>
      this != RemotePhase.idle &&
      this != RemotePhase.failed &&
      this != RemotePhase.disconnected;
}

sealed class RemoteEvent {
  const RemoteEvent();
}

final class FrameEvent extends RemoteEvent {
  const FrameEvent(this.frame);
  final FrameMessage frame;
}

final class CursorEvent extends RemoteEvent {
  const CursorEvent(this.cursor);
  final CursorMessage cursor;
}

final class HostErrorEvent extends RemoteEvent {
  const HostErrorEvent(this.code, this.message);
  final ErrorCode code;
  final String message;
}

final class DisconnectedEvent extends RemoteEvent {
  const DisconnectedEvent(this.reason);
  final String reason;
}

final class DirListingEvent extends RemoteEvent {
  const DirListingEvent(this.requestId, this.path, this.entries);
  final int requestId;
  final String path;
  final List<FileEntry> entries;
}

final class FileChunkEvent extends RemoteEvent {
  const FileChunkEvent(this.taskId, this.offset, this.data);
  final int taskId;
  final int offset;
  final Uint8List data;
}

final class UploadAckEvent extends RemoteEvent {
  const UploadAckEvent(this.taskId, this.received);
  final int taskId;
  final int received;
}

final class FileDoneEvent extends RemoteEvent {
  const FileDoneEvent(this.taskId, this.path, this.size, this.sha256);
  final int taskId;
  final String path;
  final int size;
  final String sha256;
}

final class FileErrorEvent extends RemoteEvent {
  const FileErrorEvent(this.requestId, this.taskId, this.message);
  final int requestId;
  final int taskId;
  final String message;
}

class RemoteClient extends ChangeNotifier {
  RemoteClient({
    required this.profile,
    String? clientName,
  }) : clientName = clientName ?? 'YuanLian Flutter';

  final ConnectionProfile profile;
  final String clientName;

  final StreamController<RemoteEvent> _events =
      StreamController<RemoteEvent>.broadcast();
  Stream<RemoteEvent> get events => _events.stream;

  RemotePhase phase = RemotePhase.idle;
  RemotePhase lastActivePhase = RemotePhase.idle;
  WelcomeMessage? welcome;
  String? errorCode;
  String? errorMessage;
  bool inputAllowed = false;
  bool fileEnabled = false;
  String fileRootLabel = '';

  int framesReceived = 0;
  int bytesReceived = 0;
  int rttMs = 0;

  SecureSocket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  Timer? _heartbeat;
  Timer? _firstFrameTimeout;
  Uint8List _buffer = Uint8List(0);
  int _start = 0;
  DateTime _lastReceived = DateTime.now();
  int _pingNonce = 0;
  int? _pendingPingNonce;
  DateTime? _pendingPingAt;
  bool _closed = false;
  bool _disposed = false;

  bool get isReady => phase == RemotePhase.ready;
  bool get isAlive => phase.active;

  Future<void> connect() async {
    if (_closed || phase.active) {
      return;
    }
    _resetBeforeConnect();
    _setPhase(RemotePhase.resolving);

    late final String host;
    late final int port;
    try {
      final endpoint = _parseEndpoint(profile.address);
      host = endpoint.$1;
      port = endpoint.$2;
    } on Object catch (error) {
      _fail('地址无效：$error', code: 'invalid_address');
      return;
    }
    _setPhase(RemotePhase.connecting);
    Socket raw;
    try {
      raw = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 8),
      );
      raw.setOption(SocketOption.tcpNoDelay, true);
    } on Object catch (error) {
      _fail('无法连接 $host:$port：$error', code: 'tcp_connect_failed');
      return;
    }
    if (_disposed || _closed) {
      raw.destroy();
      return;
    }

    _setPhase(RemotePhase.securing);
    late final Uint8List expected;
    try {
      expected = parseFingerprint(profile.fingerprint);
    } on Object catch (error) {
      raw.destroy();
      _fail('指纹格式无效：$error', code: 'invalid_fingerprint');
      return;
    }
    var certificateMismatch = false;
    SecureSocket secure;
    try {
      secure = await SecureSocket.secure(
        raw,
        host: tlsServerName,
        context: SecurityContext(withTrustedRoots: false),
        onBadCertificate: (certificate) {
          final actual = sha256.convert(certificate.der).bytes;
          final matches = _bytesEqual(actual, expected);
          if (!matches) {
            certificateMismatch = true;
          }
          return matches;
        },
      ).timeout(const Duration(seconds: 10));
      final peer = secure.peerCertificate;
      if (peer == null) {
        raw.destroy();
        _fail('TLS 连接没有对端证书', code: 'tls_no_certificate');
        return;
      }
      final actual = sha256.convert(peer.der).bytes;
      if (!_bytesEqual(actual, expected)) {
        certificateMismatch = true;
        secure.destroy();
        _fail('Host 证书指纹不匹配，连接已拒绝', code: 'fingerprint_mismatch');
        return;
      }
    } on HandshakeException catch (error) {
      raw.destroy();
      _fail(
        certificateMismatch
            ? 'Host 证书指纹不匹配，连接已拒绝'
            : 'TLS 握手失败：$error',
        code: certificateMismatch ? 'fingerprint_mismatch' : 'tls_failed',
      );
      return;
    } on Object catch (error) {
      raw.destroy();
      _fail('TLS 握手失败：$error', code: 'tls_failed');
      return;
    }
    if (_disposed || _closed) {
      secure.destroy();
      return;
    }

    _socket = secure;
    _lastReceived = DateTime.now();
    _setPhase(RemotePhase.waitingWelcome);
    _subscription = secure.listen(
      _onData,
      onError: _onSocketError,
      onDone: _onSocketDone,
      cancelOnError: false,
    );
    _send(
      encodeHello(
        clientName: clientName,
        clientId: 'flutter-${_safeHostname()}-$pid',
        requestInput: true,
      ),
    );
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) => _heartbeatTick());
  }

  void _resetBeforeConnect() {
    errorCode = null;
    errorMessage = null;
    welcome = null;
    inputAllowed = false;
    framesReceived = 0;
    bytesReceived = 0;
    rttMs = 0;
    _buffer = Uint8List(0);
    _start = 0;
    _pendingPingNonce = null;
    _pendingPingAt = null;
  }

  void _setPhase(RemotePhase value) {
    if (_disposed || phase == value) {
      return;
    }
    phase = value;
    if (value.active) {
      lastActivePhase = value;
    }
    notifyListeners();
  }

  void _onData(Uint8List data) {
    if (_closed) {
      return;
    }
    _lastReceived = DateTime.now();
    _append(data);
    while (_start + 4 <= _buffer.length) {
      final length = (_buffer[_start] << 24) |
          (_buffer[_start + 1] << 16) |
          (_buffer[_start + 2] << 8) |
          _buffer[_start + 3];
      if (length <= 0 || length > maxMessageBytes) {
        _fail('Host 发送了非法消息长度：$length', code: 'bad_message');
        return;
      }
      if (_start + 4 + length > _buffer.length) {
        break;
      }
      final payload = Uint8List.sublistView(
        _buffer,
        _start + 4,
        _start + 4 + length,
      );
      _start += 4 + length;
      try {
        _handleMessage(decodeServerMessage(payload));
      } on ProtocolException catch (error) {
        _fail('协议解析失败：${error.message}', code: 'bad_message');
        return;
      }
    }
    _compactBuffer();
    if (phase == RemotePhase.disconnected && _socket != null) {
      _closeSocket();
    }
  }

  void _append(Uint8List data) {
    final remaining = _buffer.length - _start;
    final merged = Uint8List(remaining + data.length);
    if (remaining > 0) {
      merged.setRange(0, remaining, _buffer, _start);
    }
    merged.setRange(remaining, merged.length, data);
    _buffer = merged;
    _start = 0;
  }

  void _compactBuffer() {
    if (_start == _buffer.length) {
      _buffer = Uint8List(0);
      _start = 0;
      return;
    }
    if (_start > 256 * 1024) {
      _buffer = Uint8List.fromList(
        Uint8List.sublistView(_buffer, _start),
      );
      _start = 0;
    }
  }

  void _handleMessage(ServerMessage message) {
    switch (message) {
      case WelcomeReceived(:final welcome):
        if (this.welcome != null) {
          _fail('Host 重复发送 Welcome', code: 'bad_message');
          return;
        }
        if (welcome.protocolVersion != protocolVersion) {
          _fail(
            '协议版本不兼容：Host ${welcome.protocolVersion}，客户端 $protocolVersion',
            code: 'protocol_version',
          );
          return;
        }
        this.welcome = welcome;
        inputAllowed = welcome.inputAllowed;
        _setPhase(RemotePhase.waitingFirstFrame);
        _firstFrameTimeout?.cancel();
        _firstFrameTimeout = Timer(const Duration(seconds: 15), () {
          if (phase == RemotePhase.waitingFirstFrame) {
            _fail('等待首帧超时（15 秒）', code: 'first_frame_timeout');
          }
        });
      case FrameReceived(:final frame):
        framesReceived += 1;
        bytesReceived += frame.encodedBytes;
        if (phase == RemotePhase.waitingFirstFrame) {
          _firstFrameTimeout?.cancel();
          _setPhase(RemotePhase.ready);
        }
        if (!_events.isClosed) {
          _events.add(FrameEvent(frame));
        }
      case CursorReceived(:final cursor):
        if (!_events.isClosed) {
          _events.add(CursorEvent(cursor));
        }
      case PongReceived(:final nonce):
        if (_pendingPingNonce == nonce && _pendingPingAt != null) {
          rttMs = DateTime.now().difference(_pendingPingAt!).inMilliseconds;
          _pendingPingNonce = null;
          _pendingPingAt = null;
        }
      case HostError(:final code, :final message):
        if (code == ErrorCode.inputDenied) {
          inputAllowed = false;
          notifyListeners();
        }
        if (!_events.isClosed) {
          _events.add(HostErrorEvent(code, message));
        }
        if (code == ErrorCode.screenUnavailable && phase != RemotePhase.ready) {
          _fail(message, code: code.wireName);
        }
      case FileCapabilitiesReceived(:final enabled, :final rootLabel):
        fileEnabled = enabled;
        fileRootLabel = rootLabel;
        notifyListeners();
      case DirListingReceived(:final requestId, :final path, :final entries):
        if (!_events.isClosed) {
          _events.add(DirListingEvent(requestId, path, entries));
        }
      case FileChunkReceived(:final taskId, :final offset, :final data):
        if (!_events.isClosed) {
          _events.add(FileChunkEvent(taskId, offset, data));
        }
      case UploadAckReceived(:final taskId, :final received):
        if (!_events.isClosed) {
          _events.add(UploadAckEvent(taskId, received));
        }
      case FileDoneReceived(:final taskId, :final path, :final size, :final sha256):
        if (!_events.isClosed) {
          _events.add(FileDoneEvent(taskId, path, size, sha256));
        }
      case FileErrorReceived(:final requestId, :final taskId, :final message):
        if (!_events.isClosed) {
          _events.add(FileErrorEvent(requestId, taskId, message));
        }
      case ByeReceived(:final reason):
        _disconnectInternal(
          reason.isEmpty ? 'Host 结束了会话' : reason,
          notifyHost: false,
        );
    }
  }

  void _heartbeatTick() {
    if (_closed) {
      return;
    }
    if (DateTime.now().difference(_lastReceived) > const Duration(seconds: 30)) {
      _fail('心跳超时（30 秒未收到 Host 消息）', code: 'heartbeat_timeout');
      return;
    }
    _pingNonce += 1;
    _pendingPingNonce = _pingNonce;
    _pendingPingAt = DateTime.now();
    _send(encodePing(_pingNonce));
  }

  void _onSocketError(Object error) {
    if (_closed) {
      return;
    }
    _disconnectInternal(
      '连接错误：$error',
      notifyHost: false,
    );
  }

  void _onSocketDone() {
    if (_closed) {
      return;
    }
    _disconnectInternal(
      phase == RemotePhase.ready ? 'Host 关闭了连接' : '连接被关闭',
      notifyHost: false,
    );
  }

  void _fail(String message, {String? code}) {
    if (_closed) {
      return;
    }
    errorMessage = message;
    errorCode = code ?? 'unknown';
    if (phase.active) {
      lastActivePhase = phase;
    }
    _firstFrameTimeout?.cancel();
    _heartbeat?.cancel();
    phase = RemotePhase.failed;
    _closeSocket();
    notifyListeners();
  }

  void _disconnectInternal(String reason, {required bool notifyHost}) {
    if (_closed) {
      return;
    }
    if (phase.active) {
      lastActivePhase = phase;
    }
    _firstFrameTimeout?.cancel();
    _heartbeat?.cancel();
    if (notifyHost) {
      _send(encodeBye());
    }
    phase = phase == RemotePhase.failed
        ? RemotePhase.failed
        : RemotePhase.disconnected;
    _closeSocket();
    if (!_events.isClosed) {
      _events.add(DisconnectedEvent(reason));
    }
    notifyListeners();
  }

  void _closeSocket() {
    _heartbeat?.cancel();
    _firstFrameTimeout?.cancel();
    _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    _closed = true;
    try {
      socket?.destroy();
    } on Object {
      // Already gone.
    }
  }

  void disconnect({String reason = '已手动断开连接'}) {
    if (_socket == null && phase == RemotePhase.disconnected) {
      return;
    }
    _disconnectInternal(reason, notifyHost: true);
  }

  void requestKeyframe() => _send(encodeRequestKeyframe());

  void sendMouseMove(int x, int y) {
    if (!inputAllowed) {
      return;
    }
    _send(encodeMouseMove(x, y));
  }

  void sendMouseButton(HostMouseButton button, bool down) {
    if (!inputAllowed) {
      return;
    }
    _send(encodeMouseButton(button, down));
  }

  void sendWheel(int vertical, int horizontal) {
    if (!inputAllowed || (vertical == 0 && horizontal == 0)) {
      return;
    }
    _send(encodeWheel(vertical, horizontal));
  }

  void sendKey(int vk, bool down, bool extended) {
    if (!inputAllowed) {
      return;
    }
    _send(encodeKey(vk, down, extended));
  }

  void sendReleaseAll() {
    _send(encodeReleaseAll());
  }

  void requestFileList(int requestId, String path) =>
      _send(encodeFileList(requestId, path));

  void startFileDownload(int taskId, String path) =>
      _send(encodeFileDownload(taskId, path));

  void startFileUpload(
    int taskId,
    String path,
    int size,
    bool overwrite,
  ) =>
      _send(encodeUploadStart(taskId, path, size, overwrite));

  void sendUploadChunk(int taskId, int offset, Uint8List data) =>
      _send(encodeUploadChunk(taskId, offset, data));

  void finishUpload(int taskId) => _send(encodeUploadFinish(taskId));

  void cancelFileTask(int taskId) => _send(encodeFileCancel(taskId));

  /// Local text submission for Chinese/emoji. The Host injects committed
  /// UTF-16 text; this is not a remote IME composition implementation.
  void sendText(String text) {
    if (!inputAllowed || text.isEmpty || text.length > 4096) {
      return;
    }
    _send(encodeTextInput(text));
  }

  void _send(Uint8List payload) {
    final socket = _socket;
    if (socket == null || _closed) {
      return;
    }
    try {
      socket.add(framePayload(payload));
    } on Object catch (error) {
      _fail('发送数据失败：$error', code: 'send_failed');
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _closed = true;
    _heartbeat?.cancel();
    _firstFrameTimeout?.cancel();
    _subscription?.cancel();
    try {
      _socket?.destroy();
    } on Object {
      // Ignore.
    }
    _socket = null;
    _events.close();
    super.dispose();
  }
}

(String, int) _parseEndpoint(String input) {
  final text = input.trim();
  if (text.startsWith('[')) {
    final end = text.indexOf(']');
    if (end < 0) {
      throw const FormatException('IPv6 地址缺少右方括号');
    }
    final host = text.substring(1, end);
    final rest = text.substring(end + 1);
    final port = rest.startsWith(':')
        ? int.parse(rest.substring(1))
        : defaultPort;
    if (port < 1 || port > 65535) {
      throw const FormatException('端口必须在 1-65535 之间');
    }
    return (host, port);
  }
  final colon = text.lastIndexOf(':');
  if (colon < 0) {
    return (text, defaultPort);
  }
  if (text.indexOf(':') != colon) {
    throw const FormatException('IPv6 地址请使用 [地址]:端口 格式');
  }
  final host = text.substring(0, colon);
  final port = int.parse(text.substring(colon + 1));
  if (host.isEmpty || port < 1 || port > 65535) {
    throw const FormatException('地址或端口无效');
  }
  return (host, port);
}

Uint8List parseFingerprint(String input) {
  final clean = input.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (clean.length != 64) {
    throw const FormatException('指纹必须是 64 个十六进制字符');
  }
  final result = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    result[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

String _safeHostname() {
  try {
    return Platform.localHostname;
  } on Object {
    return 'device';
  }
}
