import 'dart:async';

import 'quality_integrity.dart';
import 'quality_native_process.dart';
import 'quality_preview.dart';

class QualityApp {
  const QualityApp(this.name, this.id, this.hdr);
  final String name;
  final int id;
  final bool hdr;
}

class QualityAppsException implements Exception {
  const QualityAppsException(this.message);
  final String message;
}

/// A short-lived, read-only query using Moonlight's existing pairing identity.
/// It does not fetch credentials or create a pairing. Output is bounded and is
/// parsed in memory; raw stdout/stderr must never be logged or shown in the UI.
class QualityAppQuery {
  NativeQualityChild? _child;
  bool _cancelled = false;
  bool _busy = false;

  Future<List<QualityApp>> load(
    String executable,
    String host, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (_busy) throw const QualityAppsException('应用列表正在查询中。');
    final config = QualityPreviewConfig(
      host: host,
      app: 'Desktop',
      resolution: '1920x1080',
      fps: 60,
      bitrateKbps: 20000,
    );
    final problem = config.validate();
    if (problem != null) throw QualityAppsException(problem);
    _busy = true;
    _cancelled = false;
    try {
      await QualityIntegrity.verify(executable);
      if (_cancelled) throw const QualityAppsException('查询已取消。');
      final child = await NativeQualityChild.start(executable, [
        'list',
        '--csv',
        host.trim(),
      ], capture: true);
      _child = child;
      if (_cancelled) await child.terminate();
      final code = await child.exitCode.timeout(timeout);
      if (_cancelled) throw const QualityAppsException('查询已取消。');
      if (child.overflow) throw const QualityAppsException('应用列表超过安全上限，已结束查询。');
      if (code != 0) {
        throw const QualityAppsException(
          '无法读取应用列表：请先在 Moonlight 中完成配对，并确认 Host 在线。',
        );
      }
      return parseCsv(child.output);
    } on TimeoutException {
      if (_cancelled) throw const QualityAppsException('查询已取消。');
      throw const QualityAppsException('应用列表查询超时，已结束查询；请检查地址、网络和配对状态。');
    } on QualityIntegrityException {
      rethrow;
    } on QualityAppsException {
      rethrow;
    } on Object {
      throw const QualityAppsException('应用列表查询失败，请检查客户端和组件版本。');
    } finally {
      final child = _child;
      if (child != null) {
        await child.terminate();
        try {
          await child.exitCode.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          throw const QualityAppsException('尚未确认查询进程退出，请关闭客户端后重试。');
        }
      }
      _child = null;
      _busy = false;
    }
  }

  void cancel() {
    _cancelled = true;
    final child = _child;
    if (child != null) unawaited(child.terminate());
  }

  static List<QualityApp> parseCsv(String text) {
    if (text.length > 65536) throw const QualityAppsException('应用列表超过安全上限。');
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    if (lines.last.isEmpty) lines.removeLast();
    if (lines.isEmpty ||
        lines.length > 257 ||
        lines.first.trim() !=
            'Name, ID, HDR Support, App Collection Game, Hidden, Direct Launch, Boxart URL') {
      throw const QualityAppsException('Moonlight 返回了无法识别的应用列表格式；请使用上游 GUI。');
    }
    final apps = <QualityApp>[];
    final ids = <int>{};
    final names = <String>{};
    for (final line in lines.skip(1)) {
      final fields = _row(line);
      final id = fields.length == 7 ? int.tryParse(fields[1]) : null;
      if (fields.length != 7 ||
          id == null ||
          id < 0 ||
          !ids.add(id) ||
          fields[0].isEmpty ||
          fields[0].length > 128 ||
          fields[0].startsWith('-') ||
          fields[0].contains(RegExp(r'[\x00-\x1f\x7f]')) ||
          !names.add(fields[0]) ||
          fields
              .sublist(2, 6)
              .any((value) => value != 'true' && value != 'false')) {
        throw const QualityAppsException('应用列表包含不支持或有歧义的条目；请使用上游 GUI。');
      }
      apps.add(QualityApp(fields[0], id, fields[2] == 'true'));
    }
    return apps;
  }

  static List<String> _row(String text) {
    final fields = <String>[];
    var buffer = StringBuffer();
    var quoted = false;
    var closed = false;
    for (var index = 0; index < text.length; index++) {
      final ch = text[index];
      if (quoted) {
        if (ch == '"') {
          if (index + 1 < text.length && text[index + 1] == '"') {
            buffer.write('"');
            index++;
          } else {
            quoted = false;
            closed = true;
          }
        } else {
          buffer.write(ch);
        }
      } else if (ch == ',') {
        fields.add(buffer.toString());
        buffer = StringBuffer();
        closed = false;
      } else if (ch == '"' && buffer.isEmpty && !closed) {
        quoted = true;
      } else {
        if (closed || ch == '"') {
          throw const QualityAppsException('应用名称 CSV 格式不支持，请使用上游 GUI。');
        }
        buffer.write(ch);
      }
    }
    if (quoted) throw const QualityAppsException('应用列表数据不完整。');
    fields.add(buffer.toString());
    return fields;
  }
}
