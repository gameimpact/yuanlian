import 'dart:typed_data';

import 'bincode.dart';

const int protocolVersion = 2;
const int defaultPort = 24800;
const String tlsServerName = 'yuanlian.local';
const int maxMessageBytes = 32 * 1024 * 1024;

const int featureFileTransfer = 1 << 0;
const int featureTextInput = 1 << 1;
const int featureSessionTicket = 1 << 2;

const int permissionView = 1 << 0;
const int permissionControl = 1 << 1;
const int permissionFileRead = 1 << 2;
const int permissionFileWrite = 1 << 3;
const int permissionFileDelete = 1 << 4;

String permissionSummary(int bits) {
  final names = <String>[
    if (bits & permissionView != 0) '查看',
    if (bits & permissionControl != 0) '控制',
    if (bits & permissionFileRead != 0) '读取文件',
    if (bits & permissionFileWrite != 0) '写入文件',
    if (bits & permissionFileDelete != 0) '删除文件',
  ];
  return names.isEmpty ? '无权限' : names.join('、');
}

// ServerMessage enum indices (Rust declaration order).
const int _serverWelcome = 0;
const int _serverFrame = 1;
const int _serverCursor = 2;
const int _serverPong = 3;
const int _serverError = 4;
const int _serverBye = 5;
const int _serverFileCapabilities = 6;
const int _serverDirListing = 7;
const int _serverFileChunk = 8;
const int _serverUploadAck = 9;
const int _serverFileDone = 10;
const int _serverFileError = 11;

// ClientMessage enum indices.
const int _clientHello = 0;
const int _clientInput = 1;
const int _clientRequestKeyframe = 2;
const int _clientPing = 3;
const int _clientBye = 4;
const int _clientFileList = 5;
const int _clientFileDownload = 6;
const int _clientUploadStart = 7;
const int _clientUploadChunk = 8;
const int _clientUploadFinish = 9;
const int _clientFileCancel = 10;
const int _clientTextInput = 11;

// InputEvent enum indices.
const int _inputMouseMove = 0;
const int _inputMouseButton = 1;
const int _inputWheel = 2;
const int _inputKey = 3;
const int _inputReleaseAll = 4;

enum HostMouseButton { left, right, middle, back, forward }

class WelcomeMessage {
  const WelcomeMessage({
    required this.protocolVersion,
    required this.hostId,
    required this.hostName,
    required this.screenWidth,
    required this.screenHeight,
    required this.inputAllowed,
    required this.mode,
    required this.tileSize,
    required this.authenticated,
    required this.account,
    required this.permissions,
    required this.authMode,
    required this.sessionId,
    required this.ticketExpiresAt,
  });

  final int protocolVersion;
  final String hostId;
  final String hostName;
  final int screenWidth;
  final int screenHeight;
  final bool inputAllowed;
  final String mode;
  final int tileSize;
  final bool authenticated;
  final String account;
  final int permissions;
  final String authMode;
  final String sessionId;
  final int ticketExpiresAt;
}

class TileData {
  const TileData({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.jpeg,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  final Uint8List jpeg;
}

class FrameMessage {
  const FrameMessage({
    required this.seq,
    required this.generation,
    required this.full,
    required this.width,
    required this.height,
    required this.tiles,
  });

  final int seq;
  final int generation;
  final bool full;
  final int width;
  final int height;
  final List<TileData> tiles;

  int get encodedBytes =>
      tiles.fold(0, (total, tile) => total + tile.jpeg.length);
}

class CursorMessage {
  const CursorMessage(this.x, this.y, this.visible);
  final int x;
  final int y;
  final bool visible;
}

enum ErrorCode {
  protocolVersion('protocol_version'),
  badMessage('bad_message'),
  inputDenied('input_denied'),
  screenUnavailable('screen_unavailable'),
  internal('internal'),
  busy('busy'),
  unauthorized('unauthorized'),
  ticketExpired('ticket_expired'),
  ticketReplay('ticket_replay'),
  permissionDenied('permission_denied'),
  revoked('revoked');

  const ErrorCode(this.wireName);
  final String wireName;

  static ErrorCode fromIndex(int index) {
    if (index < 0 || index >= ErrorCode.values.length) {
      return ErrorCode.internal;
    }
    return ErrorCode.values[index];
  }
}

class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modifiedMs,
  });

  final String name;
  final String path;
  final bool isDir;
  final int size;
  final int modifiedMs;
}

sealed class ServerMessage {
  const ServerMessage();
}

final class WelcomeReceived extends ServerMessage {
  const WelcomeReceived(this.welcome);
  final WelcomeMessage welcome;
}

final class FrameReceived extends ServerMessage {
  const FrameReceived(this.frame);
  final FrameMessage frame;
}

final class CursorReceived extends ServerMessage {
  const CursorReceived(this.cursor);
  final CursorMessage cursor;
}

final class PongReceived extends ServerMessage {
  const PongReceived(this.nonce);
  final int nonce;
}

final class HostError extends ServerMessage {
  const HostError(this.code, this.message);
  final ErrorCode code;
  final String message;
}

final class ByeReceived extends ServerMessage {
  const ByeReceived(this.reason);
  final String reason;
}

final class FileCapabilitiesReceived extends ServerMessage {
  const FileCapabilitiesReceived(
    this.enabled,
    this.rootLabel, {
    this.read = false,
    this.write = false,
    this.delete = false,
  });
  final bool enabled;
  final String rootLabel;
  final bool read;
  final bool write;
  final bool delete;
}

final class DirListingReceived extends ServerMessage {
  const DirListingReceived(this.requestId, this.path, this.entries);
  final int requestId;
  final String path;
  final List<FileEntry> entries;
}

final class FileChunkReceived extends ServerMessage {
  const FileChunkReceived(this.taskId, this.offset, this.data);
  final int taskId;
  final int offset;
  final Uint8List data;
}

final class UploadAckReceived extends ServerMessage {
  const UploadAckReceived(this.taskId, this.received);
  final int taskId;
  final int received;
}

final class FileDoneReceived extends ServerMessage {
  const FileDoneReceived(this.taskId, this.path, this.size, this.sha256);
  final int taskId;
  final String path;
  final int size;
  final String sha256;
}

final class FileErrorReceived extends ServerMessage {
  const FileErrorReceived(this.requestId, this.taskId, this.message);
  final int requestId;
  final int taskId;
  final String message;
}

ServerMessage decodeServerMessage(Uint8List payload) {
  final reader = ByteReader(payload);
  final tag = reader.u32();
  final message = switch (tag) {
    _serverWelcome => _decodeWelcome(reader),
    _serverFrame => _decodeFrame(reader),
    _serverCursor => _decodeCursor(reader),
    _serverPong => PongReceived(reader.u64()),
    _serverError => _decodeError(reader),
    _serverBye => ByeReceived(reader.string()),
    _serverFileCapabilities => FileCapabilitiesReceived(
        reader.boolean(),
        reader.string(),
        read: reader.boolean(),
        write: reader.boolean(),
        delete: reader.boolean(),
      ),
    _serverDirListing => _decodeDirListing(reader),
    _serverFileChunk => FileChunkReceived(
        reader.u64(),
        reader.u64(),
        reader.bytes(),
      ),
    _serverUploadAck => UploadAckReceived(reader.u64(), reader.u64()),
    _serverFileDone => FileDoneReceived(
        reader.u64(),
        reader.string(),
        reader.u64(),
        reader.string(),
      ),
    _serverFileError => FileErrorReceived(
        reader.u64(),
        reader.u64(),
        reader.string(),
      ),
    _ => throw ProtocolException('unknown server message tag $tag'),
  };
  reader.expectEnd();
  return message;
}

WelcomeReceived _decodeWelcome(ByteReader reader) {
  return WelcomeReceived(
    WelcomeMessage(
      protocolVersion: reader.u16(),
      hostId: reader.string(),
      hostName: reader.string(),
      screenWidth: reader.u32(),
      screenHeight: reader.u32(),
      inputAllowed: reader.boolean(),
      mode: reader.string(),
      tileSize: reader.u32(),
      authenticated: reader.boolean(),
      account: reader.string(),
      permissions: reader.u32(),
      authMode: reader.string(),
      sessionId: reader.string(),
      ticketExpiresAt: reader.u64(),
    ),
  );
}

FrameReceived _decodeFrame(ByteReader reader) {
  final seq = reader.u64();
  final generation = reader.u32();
  final full = reader.boolean();
  final width = reader.u32();
  final height = reader.u32();
  final count = reader.u64();
  if (count > 8192) {
    throw ProtocolException('too many tiles: $count');
  }
  final tiles = <TileData>[];
  for (var i = 0; i < count; i++) {
    tiles.add(
      TileData(
        x: reader.u32(),
        y: reader.u32(),
        width: reader.u32(),
        height: reader.u32(),
        jpeg: reader.bytes(maxBytes: 4 * 1024 * 1024),
      ),
    );
  }
  return FrameReceived(
    FrameMessage(
      seq: seq,
      generation: generation,
      full: full,
      width: width,
      height: height,
      tiles: tiles,
    ),
  );
}

CursorReceived _decodeCursor(ByteReader reader) {
  return CursorReceived(
    CursorMessage(reader.i32(), reader.i32(), reader.boolean()),
  );
}

HostError _decodeError(ByteReader reader) {
  return HostError(
    ErrorCode.fromIndex(reader.u32()),
    reader.string(),
  );
}

DirListingReceived _decodeDirListing(ByteReader reader) {
  final requestId = reader.u64();
  final path = reader.string();
  final count = reader.u64();
  if (count > 10000) {
    throw ProtocolException('too many directory entries: $count');
  }
  final entries = <FileEntry>[];
  for (var i = 0; i < count; i++) {
    entries.add(
      FileEntry(
        name: reader.string(),
        path: reader.string(),
        isDir: reader.boolean(),
        size: reader.u64(),
        modifiedMs: reader.u64(),
      ),
    );
  }
  return DirListingReceived(requestId, path, entries);
}

Uint8List encodeHello({
  required String clientName,
  required String clientId,
  required bool requestInput,
  int features = featureFileTransfer | featureTextInput | featureSessionTicket,
  String? sessionTicket,
  String sessionNonce = '',
}) {
  final writer = ByteWriter()
    ..u32(_clientHello)
    ..u16(protocolVersion)
    ..string(clientName)
    ..string(clientId)
    ..boolean(requestInput)
    ..u32(features);
  if (sessionTicket == null) {
    writer.boolean(false);
  } else {
    writer
      ..boolean(true)
      ..string(sessionTicket);
  }
  writer.string(sessionNonce);
  return writer.toBytes();
}

Uint8List encodeMouseMove(int x, int y) {
  final writer = ByteWriter()
    ..u32(_clientInput)
    ..u32(_inputMouseMove)
    ..i32(x)
    ..i32(y);
  return writer.toBytes();
}

Uint8List encodeMouseButton(HostMouseButton button, bool down) {
  final writer = ByteWriter()
    ..u32(_clientInput)
    ..u32(_inputMouseButton)
    ..u32(button.index)
    ..boolean(down);
  return writer.toBytes();
}

Uint8List encodeWheel(int vertical, int horizontal) {
  final writer = ByteWriter()
    ..u32(_clientInput)
    ..u32(_inputWheel)
    ..i32(vertical)
    ..i32(horizontal);
  return writer.toBytes();
}

Uint8List encodeKey(int vk, bool down, bool extended) {
  final writer = ByteWriter()
    ..u32(_clientInput)
    ..u32(_inputKey)
    ..u16(vk)
    ..boolean(down)
    ..boolean(extended);
  return writer.toBytes();
}

Uint8List encodeReleaseAll() {
  final writer = ByteWriter()
    ..u32(_clientInput)
    ..u32(_inputReleaseAll);
  return writer.toBytes();
}

Uint8List encodeRequestKeyframe() {
  final writer = ByteWriter()..u32(_clientRequestKeyframe);
  return writer.toBytes();
}

Uint8List encodePing(int nonce) {
  final writer = ByteWriter()
    ..u32(_clientPing)
    ..u64(nonce);
  return writer.toBytes();
}

Uint8List encodeBye() {
  final writer = ByteWriter()..u32(_clientBye);
  return writer.toBytes();
}

Uint8List encodeFileList(int requestId, String path) {
  final writer = ByteWriter()
    ..u32(_clientFileList)
    ..u64(requestId)
    ..string(path);
  return writer.toBytes();
}

Uint8List encodeFileDownload(int taskId, String path) {
  final writer = ByteWriter()
    ..u32(_clientFileDownload)
    ..u64(taskId)
    ..string(path);
  return writer.toBytes();
}

Uint8List encodeUploadStart(
  int taskId,
  String path,
  int size,
  bool overwrite,
) {
  final writer = ByteWriter()
    ..u32(_clientUploadStart)
    ..u64(taskId)
    ..string(path)
    ..u64(size)
    ..boolean(overwrite);
  return writer.toBytes();
}

Uint8List encodeUploadChunk(int taskId, int offset, Uint8List data) {
  final writer = ByteWriter()
    ..u32(_clientUploadChunk)
    ..u64(taskId)
    ..u64(offset)
    ..bytes(data);
  return writer.toBytes();
}

Uint8List encodeUploadFinish(int taskId) {
  final writer = ByteWriter()
    ..u32(_clientUploadFinish)
    ..u64(taskId);
  return writer.toBytes();
}

Uint8List encodeFileCancel(int taskId) {
  final writer = ByteWriter()
    ..u32(_clientFileCancel)
    ..u64(taskId);
  return writer.toBytes();
}

Uint8List encodeTextInput(String text) {
  final writer = ByteWriter()
    ..u32(_clientTextInput)
    ..string(text);
  return writer.toBytes();
}

/// Prepends the big-endian u32 length used by the Host framing.
Uint8List framePayload(Uint8List payload) {
  if (payload.length > maxMessageBytes) {
    throw ProtocolException('message too large: ${payload.length}');
  }
  final framed = Uint8List(4 + payload.length);
  ByteData.sublistView(framed, 0, 4)
      .setUint32(0, payload.length, Endian.big);
  framed.setRange(4, framed.length, payload);
  return framed;
}
