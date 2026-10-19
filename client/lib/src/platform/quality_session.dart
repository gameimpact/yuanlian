import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'quality_native_process.dart';
import 'quality_integrity.dart';

typedef QualityProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

enum QualityProcessState { idle, starting, running, stopping, exited, failed }

/// Owns only the process started by this launcher, never other Moonlight or
/// Sunshine instances. A running process is not proof of an active video stream.
class QualitySession extends ChangeNotifier {
  QualitySession({QualityProcessStarter? starter})
    : _starter = starter == null
          ? _startProcess
          : ((exe, args) async => DartQualityChild(await starter(exe, args)));

  final Future<QualityChild> Function(String, List<String>) _starter;
  QualityChild? _process;
  bool _disposed = false;
  QualityProcessState state = QualityProcessState.idle;
  int? exitCode;
  String? error;
  bool pairing = false;

  int? get pid => _process?.pid;
  bool get busy => state == QualityProcessState.starting || _process != null;

  static Future<QualityChild> _startProcess(
    String exe,
    List<String> arguments,
  ) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows quality preview only');
    }
    await QualityIntegrity.verify(exe);
    return NativeQualityChild.start(exe, arguments);
  }

  Future<void> start(
    String executable,
    List<String> arguments, {
    bool forPairing = false,
  }) async {
    if (_disposed || busy) {
      throw StateError('已有本页启动的 Moonlight 正在运行或启动中。');
    }
    state = QualityProcessState.starting;
    pairing = forPairing;
    exitCode = null;
    error = null;
    notifyListeners();
    try {
      final process = await _starter(executable, arguments);
      // Drain immediately and discard: upstream output can include pairing
      // details. Unread pipes can block the GUI; output must not enter our logs.
      unawaited(process.stdout.drain<void>().catchError((Object _) {}));
      unawaited(process.stderr.drain<void>().catchError((Object _) {}));
      if (_disposed) {
        await process.terminate();
        return;
      }
      _process = process;
      state = QualityProcessState.running;
      notifyListeners();
      unawaited(_observeExit(process));
    } on QualityIntegrityException catch (problem) {
      if (!_disposed) {
        state = QualityProcessState.failed;
        error = problem.message;
        notifyListeners();
      }
    } on Object {
      if (!_disposed) {
        state = QualityProcessState.failed;
        error =
            '无法安全启动 Moonlight。请检查程序路径、运行库和客户端版本；需要支持 Job Object 的 Windows 构建。';
        notifyListeners();
      }
    }
  }

  Future<void> _observeExit(QualityChild process) async {
    final code = await process.exitCode;
    if (!identical(_process, process)) return;
    final requestedStop = state == QualityProcessState.stopping;
    _process = null;
    exitCode = code;
    state = code == 0 || requestedStop
        ? QualityProcessState.exited
        : QualityProcessState.failed;
    if (state == QualityProcessState.failed) {
      error =
          'Moonlight 已异常退出（退出码 $code）。请在 Moonlight 中检查配对、'
          'Host 可达性、应用名称和编解码能力。';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> stop() async {
    final process = _process;
    if (process == null || state == QualityProcessState.stopping) return;
    error = null;
    state = QualityProcessState.stopping;
    if (!_disposed) notifyListeners();
    if (!await process.terminate()) {
      if (!identical(_process, process)) return;
      state = QualityProcessState.running;
      error = '未能结束本页启动的进程。请关闭对应 Moonlight 窗口后重试。';
      if (!_disposed) notifyListeners();
      return;
    }
    if (!identical(_process, process)) return;
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      if (identical(_process, process)) {
        state = QualityProcessState.running;
        error = '尚未确认 Moonlight 退出，请手动关闭对应窗口。';
        if (!_disposed) notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // Best effort during teardown; normal page navigation awaits stop() first.
    final process = _process;
    if (process != null) unawaited(process.terminate());
    super.dispose();
  }
}
