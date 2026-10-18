import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Outcome of an atomic, no-replace file commit.
enum CommitStatus {
  /// The temporary file was renamed to the target; the target did not exist.
  committed,

  /// The target already exists. The existing file was not touched.
  targetExists,
}

class FileCommitException implements Exception {
  FileCommitException(this.message, [this.errorCode]);

  final String message;
  final int? errorCode;

  @override
  String toString() => errorCode == null ? message : '$message (errno $errorCode)';
}

/// Moves [temp] to [target] without ever replacing an existing target.
///
/// The check and the rename are a single operating-system operation, so a file
/// created by another process between a pre-flight check and this call is
/// preserved and reported as [CommitStatus.targetExists]. Both paths must be on
/// the same filesystem; the caller creates the temporary file next to the
/// target.
///
/// Windows uses `MoveFileExW` without `MOVEFILE_REPLACE_EXISTING`. Linux and
/// Android use `renameat2(RENAME_NOREPLACE)` and fall back to `link(2)`, which
/// also fails with `EEXIST` instead of replacing.
CommitStatus commitNoReplace(File temp, File target) {
  if (!temp.existsSync()) {
    throw FileCommitException('临时文件不存在：${temp.path}');
  }
  if (Platform.isWindows) {
    return _commitWindows(temp, target);
  }
  if (Platform.isLinux || Platform.isAndroid) {
    return _commitPosix(temp, target);
  }
  throw FileCommitException('当前平台不支持无覆盖原子提交：${Platform.operatingSystem}');
}

const int _errorFileExists = 80;
const int _errorAlreadyExists = 183;
const int _errorFileNameExisted = 114;

CommitStatus _commitWindows(File temp, File target) {
  final source = temp.absolute.path.toNativeUtf16();
  final destination = target.absolute.path.toNativeUtf16();
  try {
    final result = _moveFileExW(source, destination, _moveFileWriteThrough);
    if (result != 0) {
      return CommitStatus.committed;
    }
    final error = _getLastError();
    if (error == _errorFileExists ||
        error == _errorAlreadyExists ||
        error == _errorFileNameExisted ||
        // GetLastError is thread-local and some embedders may lose it between
        // FFI entries. The target existing after a failed no-replace move is
        // still unambiguous for the caller's purpose: never overwrite it.
        (error == 0 && target.existsSync())) {
      return CommitStatus.targetExists;
    }
    throw FileCommitException('MoveFileExW 提交失败', error);
  } finally {
    calloc.free(source);
    calloc.free(destination);
  }
}

const int _moveFileWriteThrough = 0x8;
const int _atFdcwd = -100;
const int _renameNoReplace = 1;

const int _eexist = 17;
const int _enosys = 38;
const int _einval = 22;
const int _enotsup = 95;

CommitStatus _commitPosix(File temp, File target) {
  final source = temp.absolute.path.toNativeUtf8();
  final destination = target.absolute.path.toNativeUtf8();
  try {
    final renameat2 = _renameat2;
    if (renameat2 != null) {
      final result = renameat2(
        _atFdcwd,
        source,
        _atFdcwd,
        destination,
        _renameNoReplace,
      );
      if (result == 0) {
        return CommitStatus.committed;
      }
      final error = _errnoValue();
      if (error == _eexist) {
        return CommitStatus.targetExists;
      }
      if (error != _enosys && error != _einval && error != _enotsup) {
        throw FileCommitException('renameat2 提交失败', error);
      }
      // Fall through to link(2) on kernels/filesystems without RENAME_NOREPLACE.
    }

    final result = _link(source, destination);
    if (result != 0) {
      final error = _errnoValue();
      if (error == _eexist) {
        return CommitStatus.targetExists;
      }
      throw FileCommitException('link 提交失败', error);
    }
    _unlink(source);
    return CommitStatus.committed;
  } finally {
    calloc.free(source);
    calloc.free(destination);
  }
}

typedef _MoveFileExWNative = Int32 Function(
  Pointer<Utf16>,
  Pointer<Utf16>,
  Uint32,
);
typedef _MoveFileExWDart = int Function(Pointer<Utf16>, Pointer<Utf16>, int);
typedef _NoArgNative = Uint32 Function();
typedef _NoArgDart = int Function();
typedef _Renameat2Native = Int32 Function(
  Int32,
  Pointer<Utf8>,
  Int32,
  Pointer<Utf8>,
  Uint32,
);
typedef _Renameat2Dart = int Function(
  int,
  Pointer<Utf8>,
  int,
  Pointer<Utf8>,
  int,
);
typedef _TwoPathNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _TwoPathDart = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _OnePathNative = Int32 Function(Pointer<Utf8>);
typedef _OnePathDart = int Function(Pointer<Utf8>);
typedef _ErrnoNative = Pointer<Int32> Function();
typedef _ErrnoDart = Pointer<Int32> Function();

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final _MoveFileExWDart _moveFileExW = _kernel32
    .lookupFunction<_MoveFileExWNative, _MoveFileExWDart>('MoveFileExW');
final _NoArgDart _getLastError = _kernel32
    .lookupFunction<_NoArgNative, _NoArgDart>('GetLastError');

final DynamicLibrary _process = DynamicLibrary.process();
final _Renameat2Dart? _renameat2 = _lookupRenameat2();
final _TwoPathDart _link = _process
    .lookupFunction<_TwoPathNative, _TwoPathDart>('link');
final _OnePathDart _unlink = _process
    .lookupFunction<_OnePathNative, _OnePathDart>('unlink');
final _ErrnoDart _errno = _lookupErrno();

_Renameat2Dart? _lookupRenameat2() {
  try {
    return _process.lookupFunction<_Renameat2Native, _Renameat2Dart>(
      'renameat2',
    );
  } on Object {
    return null;
  }
}

int _errnoValue() => _errno().value;

_ErrnoDart _lookupErrno() {
  try {
    return _process.lookupFunction<_ErrnoNative, _ErrnoDart>(
      '__errno_location',
    );
  } on Object {
    return _process.lookupFunction<_ErrnoNative, _ErrnoDart>('__errno');
  }
}
