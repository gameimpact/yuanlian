import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

abstract class QualityChild {
  int get pid;
  Future<int> get exitCode;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<bool> terminate();
}

/// Used by injected process starters in tests. Production Windows launches use
/// CreateProcess(CREATE_SUSPENDED) and a private kill-on-close Job Object.
class DartQualityChild implements QualityChild {
  DartQualityChild(this.process);
  final Process process;
  @override
  int get pid => process.pid;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  Stream<List<int>> get stdout => process.stdout;
  @override
  Stream<List<int>> get stderr => process.stderr;
  @override
  Future<bool> terminate() async => process.kill();
}

class NativeQualityChild implements QualityChild {
  NativeQualityChild._(this.id, this.pid);
  static const channel = MethodChannel('yuanlian/quality-process');
  final int id;
  @override
  final int pid;
  final _exit = Completer<int>();
  String output = '';
  bool overflow = false;
  bool _released = false;

  static Future<NativeQualityChild> start(
    String executable,
    List<String> arguments, {
    bool capture = false,
    String? workingDirectory,
  }) async {
    final result = await channel.invokeMapMethod<String, dynamic>('start', {
      'executable': executable,
      'arguments': arguments,
      'capture': capture,
      'workingDirectory': ?workingDirectory,
    });
    if (result == null || result['id'] is! int || result['pid'] is! int) {
      throw StateError('Windows 原生进程监督器返回无效结果');
    }
    final child = NativeQualityChild._(
      result['id'] as int,
      result['pid'] as int,
    );
    unawaited(child._observe());
    return child;
  }

  @override
  Future<int> get exitCode => _exit.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();

  Future<void> _observe() async {
    var code = -1;
    try {
      while (true) {
        final status = await channel.invokeMapMethod<String, dynamic>('poll', {
          'id': id,
        });
        if (status == null || status['running'] is! bool) {
          throw StateError('Invalid process status');
        }
        if (status['running'] == false) {
          code = status['exitCode'] as int;
          output = status['output'] as String? ?? '';
          overflow = status['overflow'] == true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } on Object {
      // No unsafe fallback when the native supervisor is absent or fails.
      await terminate();
    } finally {
      try {
        await channel.invokeMethod<void>('release', {'id': id});
      } on Object {
        // Native window teardown/OS handle cleanup still closes the private job.
      }
      _released = true;
      if (!_exit.isCompleted) _exit.complete(code);
    }
  }

  @override
  Future<bool> terminate() async {
    if (_released) return false;
    try {
      return await channel.invokeMethod<bool>('stop', {'id': id}) ?? false;
    } on Object {
      return false;
    }
  }
}
