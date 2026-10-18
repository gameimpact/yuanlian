import 'dart:convert';
import 'dart:typed_data';

/// Little-endian, fixed-width bincode writer compatible with bincode 1.3
/// (`bincode::serialize` defaults) used by the Rust Host.
class ByteWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void u8(int value) => _builder.addByte(value & 0xff);
  void boolean(bool value) => u8(value ? 1 : 0);

  void u16(int value) {
    final data = ByteData(2)..setUint16(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void u32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void u64(int value) {
    final data = ByteData(8)..setUint64(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void i32(int value) {
    final data = ByteData(4)..setInt32(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void string(String value) {
    final bytes = utf8.encode(value);
    u64(bytes.length);
    _builder.add(bytes);
  }

  void bytes(List<int> value) {
    u64(value.length);
    _builder.add(value);
  }

  Uint8List toBytes() => _builder.toBytes();
}

class ProtocolException implements Exception {
  ProtocolException(this.message);
  final String message;

  @override
  String toString() => 'ProtocolException: $message';
}

/// Bounds-checked reader for bincode payloads.
class ByteReader {
  ByteReader(this.data) : _view = ByteData.sublistView(data);

  final Uint8List data;
  final ByteData _view;
  int offset = 0;

  int get remaining => data.length - offset;

  void _need(int count) {
    if (count < 0 || offset + count > data.length) {
      throw ProtocolException(
        'truncated payload: need $count bytes at $offset of ${data.length}',
      );
    }
  }

  int u8() {
    _need(1);
    final value = _view.getUint8(offset);
    offset += 1;
    return value;
  }

  bool boolean() => u8() != 0;

  int u16() {
    _need(2);
    final value = _view.getUint16(offset, Endian.little);
    offset += 2;
    return value;
  }

  int u32() {
    _need(4);
    final value = _view.getUint32(offset, Endian.little);
    offset += 4;
    return value;
  }

  int u64() {
    _need(8);
    final value = _view.getUint64(offset, Endian.little);
    offset += 8;
    return value;
  }

  int i32() {
    _need(4);
    final value = _view.getInt32(offset, Endian.little);
    offset += 4;
    return value;
  }

  String string() {
    final length = u64();
    if (length > remaining) {
      throw ProtocolException('string length $length exceeds payload');
    }
    final value = utf8.decode(
      Uint8List.sublistView(data, offset, offset + length),
    );
    offset += length;
    return value;
  }

  Uint8List bytes({int maxBytes = 32 * 1024 * 1024}) {
    final length = u64();
    if (length > maxBytes) {
      throw ProtocolException('byte field too large: $length');
    }
    _need(length);
    final value = Uint8List.sublistView(data, offset, offset + length);
    offset += length;
    return value;
  }

  void expectEnd() {
    if (remaining != 0) {
      throw ProtocolException('$remaining trailing bytes');
    }
  }
}
