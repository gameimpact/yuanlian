import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

/// Stores the control-plane session token in the operating system's protected
/// storage: Windows DPAPI (user scope) or the Android Keystore through a
/// MethodChannel implemented in MainActivity. Credentials are never written to
/// the profile JSON, logs or ordinary app preferences.
///
/// Linux secure storage (Secret Service) is not implemented; the store reports
/// that it is unavailable instead of persisting a plaintext token.
class CredentialStore {
  static const MethodChannel _android =
      MethodChannel('yuanlian/credentials');
  static Map<String, String> _memory = <String, String>{};

  /// Tests must never read or write the user's real credential store.
  static bool debugUseMemory = false;

  static bool get persistent =>
      Platform.isWindows || Platform.isAndroid;

  static Future<Map<String, String>> load() async {
    if (debugUseMemory) {
      return Map<String, String>.from(_memory);
    }
    try {
      if (Platform.isAndroid) {
        final value = await _android.invokeMethod<String>('load');
        if (value == null || value.isEmpty) {
          return <String, String>{};
        }
        return _decode(value);
      }
      if (Platform.isWindows) {
        final file = await _file();
        if (!await file.exists()) {
          return <String, String>{};
        }
        final protected = await file.readAsBytes();
        return _decode(_unprotect(protected));
      }
    } on Object {
      return <String, String>{};
    }
    return Map<String, String>.from(_memory);
  }

  static Future<void> save(Map<String, String> values) async {
    if (debugUseMemory) {
      _memory = Map<String, String>.from(values);
      return;
    }
    final encoded = jsonEncode(values);
    if (Platform.isAndroid) {
      await _android.invokeMethod<void>('save', encoded);
      return;
    }
    if (Platform.isWindows) {
      final file = await _file();
      await file.writeAsBytes(_protect(encoded), flush: true);
      return;
    }
    _memory = Map<String, String>.from(values);
  }

  static Future<void> clear() async {
    if (debugUseMemory) {
      _memory.clear();
      return;
    }
    if (Platform.isAndroid) {
      await _android.invokeMethod<void>('clear');
      return;
    }
    if (Platform.isWindows) {
      final file = await _file();
      if (await file.exists()) {
        await file.delete();
      }
      _memory.clear();
      return;
    }
    _memory.clear();
  }

  static Map<String, String> _decode(String encoded) {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      return <String, String>{};
    }
    return decoded.map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
  }

  static Future<File> _file() async {
    final base = Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'] ??
        Directory.systemTemp.path;
    final directory = Directory('$base${Platform.pathSeparator}YuanLian');
    await directory.create(recursive: true);
    return File(
      '${directory.path}${Platform.pathSeparator}credentials.dpapi',
    );
  }
}

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptProtectNative = Int32 Function(
  Pointer<_DataBlob>,
  Pointer<Utf16>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_DataBlob>,
);
typedef _CryptProtectDart = int Function(
  Pointer<_DataBlob>,
  Pointer<Utf16>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_DataBlob>,
);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

const int _cryptProtectUiForbidden = 0x1;

final DynamicLibrary _crypt32 = DynamicLibrary.open('crypt32.dll');
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final _CryptProtectDart _cryptProtectData = _crypt32
    .lookupFunction<_CryptProtectNative, _CryptProtectDart>(
      'CryptProtectData',
    );
final _CryptProtectDart _cryptUnprotectData = _crypt32
    .lookupFunction<_CryptProtectNative, _CryptProtectDart>(
      'CryptUnprotectData',
    );
final _LocalFreeDart _localFree = _kernel32
    .lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

List<int> _protect(String value) {
  final input = utf8.encode(value);
  final inputPointer = malloc.allocate<Uint8>(input.length);
  inputPointer.asTypedList(input.length).setAll(0, input);
  final inputBlob = malloc<_DataBlob>();
  final outputBlob = malloc<_DataBlob>();
  inputBlob.ref
    ..cbData = input.length
    ..pbData = inputPointer;
  try {
    final ok = _cryptProtectData(
      inputBlob,
      nullptr.cast<Utf16>(),
      nullptr,
      nullptr,
      nullptr,
      _cryptProtectUiForbidden,
      outputBlob,
    );
    if (ok == 0) {
      throw StateError('DPAPI CryptProtectData failed');
    }
    final length = outputBlob.ref.cbData;
    final output = List<int>.from(
      outputBlob.ref.pbData.asTypedList(length),
    );
    _localFree(outputBlob.ref.pbData.cast());
    return output;
  } finally {
    malloc.free(inputPointer);
    malloc.free(inputBlob);
    malloc.free(outputBlob);
  }
}

String _unprotect(List<int> value) {
  final inputPointer = malloc.allocate<Uint8>(value.length);
  inputPointer.asTypedList(value.length).setAll(0, value);
  final inputBlob = malloc<_DataBlob>();
  final outputBlob = malloc<_DataBlob>();
  inputBlob.ref
    ..cbData = value.length
    ..pbData = inputPointer;
  try {
    final ok = _cryptUnprotectData(
      inputBlob,
      nullptr.cast<Utf16>(),
      nullptr,
      nullptr,
      nullptr,
      _cryptProtectUiForbidden,
      outputBlob,
    );
    if (ok == 0) {
      throw StateError('DPAPI CryptUnprotectData failed');
    }
    final length = outputBlob.ref.cbData;
    final output = List<int>.from(
      outputBlob.ref.pbData.asTypedList(length),
    );
    _localFree(outputBlob.ref.pbData.cast());
    return utf8.decode(output);
  } finally {
    malloc.free(inputPointer);
    malloc.free(inputBlob);
    malloc.free(outputBlob);
  }
}
