import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../models/session_auth.dart';
import '../net/remote_client.dart';
import '../platform/quality_integrity.dart';
import '../platform/quality_native_process.dart';
import '../platform/quality_preview.dart';
import 'widgets.dart';

/// Ticket-authorized external rendering. Never presents process status as FPS.
class QualityBrokerPage extends StatefulWidget {
  const QualityBrokerPage({
    super.key,
    required this.profile,
    required this.auth,
    this.onRefreshAuth,
    this.autoStart = false,
  });
  final ConnectionProfile profile;
  final SessionAuth auth;
  final bool autoStart;
  final Future<SessionAuth?> Function()? onRefreshAuth;
  @override
  State<QualityBrokerPage> createState() => _QualityBrokerPageState();
}

class _QualityBrokerPageState extends State<QualityBrokerPage> {
  final _path = TextEditingController();
  NativeQualityChild? _child;
  RemoteClient? _remote;
  Directory? _directory;
  Future<void>? _cleanupTask;
  bool _running = false;
  bool _attempted = false;
  bool _cancelled = false;
  String _status =
      '质量模式使用视频串流。Host 验票、本机授权后开放专用 Sunshine；画面在独立 Moonlight 窗口显示。';
  @override
  void initState() {
    super.initState();
    _path.text = QualityPreviewLocator.findMoonlight() ?? '';
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start();
      });
    }
  }

  void _show(String text) {
    if (mounted) setState(() => _status = text);
  }

  void _check() {
    if (_cancelled || !mounted) throw StateError('cancelled');
  }

  Future<void> _start() async {
    _cleanupTask = null;
    _cancelled = false;
    setState(() => _running = true);
    try {
      _show('校验固定 Moonlight 组件');
      await QualityIntegrity.verify(_path.text.trim());
      _check();
      final base = Directory(
        '${Platform.environment['LOCALAPPDATA']}${Platform.pathSeparator}YuanLian${Platform.pathSeparator}quality-client-sessions',
      );
      await base.create(recursive: true);
      _check();
      final dir = await base.createTemp('client-');
      _directory = dir;
      await File('${dir.path}/portable.dat').writeAsBytes([]);
      _check();
      _show('由官方 Moonlight 生成本次独立身份；不读取既有配对私钥');
      _child = await NativeQualityChild.start(_path.text.trim(), [
        'list',
        '--csv',
        '127.0.0.1:9',
      ], workingDirectory: dir.path);
      final ini = File(
        '${dir.path}/Moonlight Game Streaming Project/Moonlight.ini',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      String? certificate;
      while (DateTime.now().isBefore(deadline)) {
        _check();
        if (await ini.exists() && await ini.length() <= 65536) {
          // Stream/skip unrelated settings. Only the public certificate crosses TLS.
          await for (final line
              in ini
                  .openRead()
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())) {
            if (!line.startsWith('certificate=')) continue;
            var value = line.substring(12);
            if (value.startsWith('"') && value.endsWith('"')) {
              value = value.substring(1, value.length - 1);
            }
            if (value.startsWith('@ByteArray(') && value.endsWith(')')) {
              final cert = value
                  .substring(11, value.length - 1)
                  .replaceAll(r'\n', '\n')
                  .replaceAll(r'\r', '\r');
              if (cert.length <= 8192 &&
                  cert.startsWith('-----BEGIN CERTIFICATE-----') &&
                  cert.trimRight().endsWith('-----END CERTIFICATE-----')) {
                certificate = cert;
              }
            }
          }
        }
        if (certificate != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await _endChild();
      _check();
      if (certificate == null) throw StateError('Moonlight 身份初始化超时');
      _show('等待 Host 验票、本机授权和专用串流端点（最长 50 秒）');
      final auth = _attempted
          ? await widget.onRefreshAuth?.call()
          : widget.auth;
      if (auth == null) throw StateError('请返回设备页获取新的单次票据');
      _check();
      _attempted = true;
      final remote = RemoteClient(
        profile: widget.profile,
        sessionTicket: auth.ticket,
        sessionNonce: auth.nonce,
        qualityCertificate: certificate,
      );
      _remote = remote;
      await remote.connect();
      final readyDeadline = DateTime.now().add(const Duration(seconds: 50));
      while (remote.qualityReady == null) {
        _check();
        if (remote.phase == RemotePhase.failed ||
            remote.phase == RemotePhase.disconnected ||
            DateTime.now().isAfter(readyDeadline)) {
          throw StateError(remote.errorMessage ?? 'Host 串流授权超时');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _check();
      final ready = remote.qualityReady!;
      final host = remote.peerAddress;
      if (host == null ||
          InternetAddress.tryParse(host)?.type != InternetAddressType.IPv4) {
        throw StateError('当前质量适配需要 IPv4');
      }
      final pem = ready.serverCertificate
          .replaceAll(r'\', r'\\')
          .replaceAll('\r', r'\r')
          .replaceAll('\n', r'\n')
          .replaceAll(')', r'\)');
      await ini.writeAsString(
        '\n[hosts]\nsize=1\n1\\hostname=YuanLian authorized quality\n1\\uuid=${ready.serverUuid}\n1\\manualaddress=$host\n1\\manualport=${ready.port}\n1\\localaddress=$host\n1\\localport=${ready.port}\n1\\nvidiasw=false\n1\\srvcert=@ByteArray($pem)\n',
        mode: FileMode.append,
        flush: true,
      );
      _check();
      _child = await NativeQualityChild.start(
        _path.text.trim(),
        QualityPreviewConfig(
          host: '$host:${ready.port}',
          app: 'Desktop',
          resolution: '1920x1080',
          fps: 60,
          bitrateKbps: 20000,
        ).toArguments(),
        workingDirectory: dir.path,
      );
      _show(
        'Host 已授权（${ready.inputAllowed ? '允许键鼠' : '仅查看'}），Moonlight 已启动。实际出画、FPS 与硬解请查看串流窗口；结束/撤权会关闭本次专用 Sunshine。',
      );
      final exit = _child!.exitCode;
      var exited = false;
      unawaited(
        exit.then((_) {
          exited = true;
        }),
      );
      while (!exited) {
        _check();
        if (remote.phase == RemotePhase.failed ||
            remote.phase == RemotePhase.disconnected) {
          throw StateError('Host 撤权或控制连接已结束');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _show('Moonlight 已退出，正在结束 Host 串流会话');
    } on QualityIntegrityException catch (e) {
      _show(e.message);
    } on Object catch (e) {
      _show(_cancelled ? '会话已结束' : '串流失败：$e');
    } finally {
      await _cleanup();
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _endChild() async {
    final child = _child;
    _child = null;
    if (child != null) {
      await child.terminate();
      await child.exitCode.timeout(const Duration(seconds: 5));
    }
  }

  Future<void> _cleanup() => _cleanupTask ??= _cleanupOwned();
  Future<void> _cleanupOwned() async {
    _remote?.dispose();
    _remote = null;
    try {
      await _endChild();
    } on Object {
      /* Native Job also closes at window teardown. */
    }
    final dir = _directory;
    _directory = null;
    if (dir != null &&
        dir.path.split(Platform.pathSeparator).last.startsWith('client-')) {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        /* Own isolated state only; never sweep parent. */
      }
    }
  }

  @override
  void dispose() {
    _cancelled = true;
    unawaited(_cleanup());
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('质量模式 · 已接入 Host 授权的视频串流')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Windows / IPv4 / 单会话 / Desktop；独立 Moonlight 窗口。尚未内嵌 Flutter，暂不提供手柄和文件通道。',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _path,
              enabled: !_running,
              decoration: const InputDecoration(
                labelText: '固定版 Moonlight.exe 路径',
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(_status),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _running || !Platform.isWindows ? null : _start,
              child: const Text('使用票据连接质量串流'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _running
                  ? () {
                      _cancelled = true;
                      unawaited(_cleanup());
                    }
                  : null,
              child: const Text('结束本次串流'),
            ),
          ],
        ),
      ),
    ),
  );
}
