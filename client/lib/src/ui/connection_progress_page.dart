import 'dart:async';

import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../models/session_auth.dart';
import '../net/remote_client.dart';
import 'design_tokens.dart';
import 'widgets.dart';
import 'workspace_page.dart';

class ConnectionProgressPage extends StatefulWidget {
  const ConnectionProgressPage({
    super.key,
    required this.profile,
    required this.onConnected,
    this.sessionAuth,
    this.onRefreshAuth,
    this.inputSelfTest = false,
    this.autoOpenFiles = false,
  });

  final ConnectionProfile profile;
  final ValueChanged<ConnectionProfile> onConnected;
  final SessionAuth? sessionAuth;
  final Future<SessionAuth?> Function()? onRefreshAuth;
  final bool inputSelfTest;
  final bool autoOpenFiles;

  @override
  State<ConnectionProgressPage> createState() => _ConnectionProgressPageState();
}

class _ConnectionProgressPageState extends State<ConnectionProgressPage> {
  late RemoteClient _client;
  SessionAuth? _auth;
  bool _transferred = false;
  bool _retrying = false;

  static const _stages = <(String, RemotePhase)>[
    ('解析地址', RemotePhase.resolving),
    ('建立 TCP 连接', RemotePhase.connecting),
    ('TLS 握手与证书指纹校验', RemotePhase.securing),
    ('等待 Host 授权', RemotePhase.waitingWelcome),
    ('等待首帧与能力协商', RemotePhase.waitingFirstFrame),
    ('会话已建立', RemotePhase.ready),
  ];

  @override
  void initState() {
    super.initState();
    _auth = widget.sessionAuth;
    _startAttempt();
  }

  void _startAttempt() {
    _client = RemoteClient(
      profile: widget.profile,
      sessionTicket: _auth?.ticket,
      sessionNonce: _auth?.nonce ?? '',
    );
    _client.addListener(_onClientChanged);
    unawaited(_client.connect());
  }

  void _onClientChanged() {
    if (!mounted || _transferred) {
      return;
    }
    if (_client.phase == RemotePhase.ready) {
      _transferred = true;
      widget.onConnected(widget.profile);
      _client.removeListener(_onClientChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => WorkspacePage(
              client: _client,
              profile: widget.profile,
              inputSelfTest: widget.inputSelfTest,
              autoOpenFiles: widget.autoOpenFiles,
            ),
          ),
        );
      });
    }
  }

  Future<void> _retry() async {
    if (_retrying) {
      return;
    }
    _retrying = true;
    try {
      if (_auth != null && widget.onRefreshAuth != null) {
        final refreshed = await widget.onRefreshAuth!();
        if (refreshed == null || !mounted) {
          return;
        }
        _auth = refreshed;
      }
      _client.removeListener(_onClientChanged);
      _client.dispose();
      if (mounted) {
        setState(_startAttempt);
      }
    } finally {
      _retrying = false;
    }
  }

  int _stageIndex() {
    final phase = _client.phase == RemotePhase.failed ||
            _client.phase == RemotePhase.disconnected
        ? _client.lastActivePhase
        : _client.phase;
    return switch (phase) {
      RemotePhase.idle => -1,
      RemotePhase.resolving => 0,
      RemotePhase.connecting => 1,
      RemotePhase.securing => 2,
      RemotePhase.waitingWelcome => 3,
      RemotePhase.waitingFirstFrame => 4,
      RemotePhase.ready => 5,
      RemotePhase.failed || RemotePhase.disconnected => -1,
    };
  }

  @override
  void dispose() {
    _client.removeListener(_onClientChanged);
    if (!_transferred) {
      _client.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: AnimatedBuilder(
              animation: _client,
              builder: (context, _) {
                final failed = _client.phase == RemotePhase.failed ||
                    _client.phase == RemotePhase.disconnected;
                final connected = _client.phase == RemotePhase.ready;
                return Panel(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: connected
                                  ? YlStatus.success.withValues(alpha: 0.14)
                                  : failed
                                      ? theme.colorScheme.error.withValues(alpha: 0.12)
                                      : theme.colorScheme.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: Icon(
                              connected
                                  ? Icons.check_rounded
                                  : failed
                                      ? Icons.error_outline_rounded
                                      : Icons.lock_outline_rounded,
                              color: connected
                                  ? YlStatus.success
                                  : failed
                                      ? theme.colorScheme.error
                                      : theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  connected
                                      ? '会话已建立'
                                      : failed
                                          ? '连接失败'
                                          : '正在连接',
                                  style: theme.textTheme.titleLarge,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${widget.profile.name} · ${widget.profile.address}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (!failed && !connected)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: _auth == null
                              ? YlStatus.warning.withValues(alpha: 0.10)
                              : YlStatus.success.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              _auth == null
                                  ? Icons.warning_amber_rounded
                                  : Icons.verified_user_outlined,
                              size: 16,
                              color: _auth == null
                                  ? YlStatus.warning
                                  : YlStatus.success,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _auth == null
                                    ? '匿名开发直连：没有账号/配对票据，Host 必须显式 --allow-anonymous，且会要求本机确认。'
                                    : '账号 ${_auth!.account} · 权限 ${_auth!.permissionLabel} · '
                                        '票据有效至 ${DateTime.fromMillisecondsSinceEpoch(_auth!.expiresAt * 1000).toLocal()}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '指纹 ${_shortFingerprint(widget.profile.fingerprint)}',
                              style: const TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 11.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '模式：兼顾模式（图块引擎）· 直连 TLS',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      ..._buildSteps(theme, failed),
                      if (failed) ...[
                        const SizedBox(height: 16),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.errorContainer.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _client.errorMessage ?? '连接已中断',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onErrorContainer,
                                ),
                              ),
                              if (_client.errorCode != null) ...[
                                const SizedBox(height: 4),
                                SelectableText(
                                  '错误码：${_client.errorCode}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onErrorContainer,
                                    fontFamily: 'Consolas',
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: failed
                                ? FilledButton.icon(
                                    onPressed: _retry,
                                    icon: const Icon(Icons.refresh_rounded, size: 18),
                                    label: const Text('重新连接'),
                                  )
                                : OutlinedButton(
                                    onPressed: () => Navigator.of(context).pop(),
                                    child: const Text('取消'),
                                  ),
                          ),
                          const SizedBox(width: 10),
                          if (failed)
                            OutlinedButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('返回'),
                            )
                          else
                            TextButton.icon(
                              onPressed: _client.errorMessage == null
                                  ? null
                                  : () => copyText(
                                      context,
                                      '${_client.errorMessage}\n${_client.errorCode ?? ""}',
                                      label: '已复制错误信息',
                                    ),
                              icon: const Icon(Icons.copy_rounded, size: 16),
                              label: const Text('复制错误'),
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSteps(ThemeData theme, bool failed) {
    final current = _stageIndex();
    final phaseFailed = _client.phase == RemotePhase.failed ||
        _client.phase == RemotePhase.disconnected;
    final widgets = <Widget>[];
    for (var i = 0; i < _stages.length; i++) {
      final (label, _) = _stages[i];
      final done = !failed && current > i;
      final active = !failed && current == i && _client.phase != RemotePhase.ready;
      final error = phaseFailed && current == i;
      final color = error
          ? theme.colorScheme.error
          : done || (failed && current > i)
              ? YlStatus.success
              : active
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: error
                    ? Icon(Icons.close_rounded, size: 17, color: color)
                    : done || (failed && current > i)
                        ? Icon(Icons.check_circle_rounded, size: 17, color: color)
                        : active
                            ? Padding(
                                padding: const EdgeInsets.all(3),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: color,
                                ),
                              )
                            : Icon(
                                Icons.radio_button_unchecked_rounded,
                                size: 15,
                                color: color,
                              ),
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: error || active
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              if (active) ...[
                const SizedBox(width: 8),
                Text(
                  '进行中',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: color,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return widgets;
  }
}

String _shortFingerprint(String fingerprint) {
  final clean = fingerprint.replaceAll(':', '').toUpperCase();
  if (clean.length <= 16) {
    return clean;
  }
  return '${clean.substring(0, 8)}…${clean.substring(clean.length - 8)}';
}
