import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../models/session_auth.dart';
import '../net/server_client.dart';
import '../platform/credential_store.dart';
import 'connection_progress_page.dart';
import 'quality_broker_page.dart';
import 'design_tokens.dart';
import 'widgets.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key, required this.onConnected});

  final ValueChanged<ConnectionProfile> onConnected;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _inviteController = TextEditingController();
  final _pairingController = TextEditingController();

  ServerApi? _api;
  AccountInfo? _account;
  List<DeviceInfo> _devices = <DeviceInfo>[];
  final Map<String, List<DeviceSession>> _sessions =
      <String, List<DeviceSession>>{};
  final Set<String> _expandedDevices = <String>{};
  bool _loading = true;
  bool _busy = false;
  String _mode = 'tiles';
  bool _registerMode = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _serverController.text = Platform.isAndroid ? '' : 'http://127.0.0.1:18080';
    _pairingController.addListener(_onPairingChanged);
    _restoreSession();
  }

  void _onPairingChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _inviteController.dispose();
    _pairingController.removeListener(_onPairingChanged);
    _pairingController.dispose();
    _api?.dispose();
    super.dispose();
  }

  Future<void> _restoreSession() async {
    final stored = await CredentialStore.load();
    final url = stored['serverUrl'] ?? '';
    final token = stored['token'] ?? '';
    if (!mounted) {
      return;
    }
    if (url.isNotEmpty) {
      _serverController.text = url;
    }
    if (url.isEmpty || token.isEmpty) {
      if (mounted) {
        setState(() => _loading = false);
      }
      return;
    }
    ServerApi api;
    try {
      api = ServerApi(baseUrl: url);
    } on Object catch (error) {
      await CredentialStore.clear();
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '已保存的服务端地址无效：$error';
        });
      }
      return;
    }
    api.token = token;
    try {
      final account = await api.me();
      final devices = await api.devices();
      if (!mounted) {
        api.dispose();
        return;
      }
      setState(() {
        _api = api;
        _account = account;
        _usernameController.text = account.username;
        _devices = devices;
        _loading = false;
      });
    } on Object catch (error) {
      api.dispose();
      await CredentialStore.clear();
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '已保存的登录已失效：${_message(error)}';
        });
      }
    }
  }

  Future<void> _signIn({required bool register}) async {
    if (_busy) {
      return;
    }
    final server = _serverController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (server.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() => _error = '请填写服务端地址、用户名和密码');
      return;
    }
    if (register && _inviteController.text.trim().isEmpty) {
      setState(() => _error = '邀请注册需要邀请码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    ServerApi? api;
    try {
      api = ServerApi(baseUrl: server);
      final info = await api.info();
      if (!info.initialized) {
        throw ServerException(0, 'not_initialized', '服务端尚未初始化，请管理员先创建账号');
      }
      final result = register
          ? await api.registerWithInvite(
              inviteCode: _inviteController.text.trim(),
              username: username,
              password: password,
            )
          : await api.login(username, password);
      final devices = await api.devices();
      await CredentialStore.save(<String, String>{
        'serverUrl': server,
        'username': result.account.username,
        'token': result.token,
      });
      if (!mounted) {
        api.dispose();
        return;
      }
      setState(() {
        _api?.dispose();
        _api = api;
        _account = result.account;
        _devices = devices;
        _notice = '已登录 ${result.account.username}；会话令牌保存在系统凭据存储中';
      });
    } on Object catch (error) {
      api?.dispose();
      if (mounted) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _logout() async {
    final api = _api;
    setState(() {
      _api = null;
      _account = null;
      _devices = <DeviceInfo>[];
      _sessions.clear();
      _expandedDevices.clear();
      _notice = '已退出登录';
      _error = null;
    });
    await CredentialStore.clear();
    if (api != null) {
      try {
        await api.logout();
      } on Object {
        // The local token is already gone; a failed server logout is not fatal.
      }
      api.dispose();
    }
  }

  Future<void> _refreshDevices() async {
    final api = _api;
    if (api == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final devices = await api.devices();
      if (!mounted) {
        return;
      }
      setState(() {
        _devices = devices;
        _notice = '设备目录已刷新（${devices.length} 台）';
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _claimPairing() async {
    final api = _api;
    final code = _pairingController.text.trim();
    if (api == null || code.isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.claimPairing(code);
      final devices = await api.devices();
      _pairingController.clear();
      if (!mounted) {
        return;
      }
      setState(() {
        _devices = devices;
        _notice = '配对成功，已获得设备访问授权';
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<SessionAuth?> _createAuth(DeviceInfo device, {String? mode}) async {
    final api = _api;
    if (api == null) {
      return null;
    }
    final nonce = _newNonce();
    try {
      final ticket = await api.sessionTicket(
        device.deviceId,
        nonce,
        mode: mode ?? _mode,
      );
      return SessionAuth(
        ticket: ticket.ticket,
        nonce: nonce,
        sessionId: ticket.sessionId,
        account: _account?.username ?? '',
        permissions: ticket.permissions,
        expiresAt: ticket.expiresAt,
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = _message(error));
      }
      return null;
    }
  }

  Future<void> _connect(DeviceInfo device) async {
    final mode = _mode;
    final auth = await _createAuth(device, mode: mode);
    if (auth == null || !mounted) {
      return;
    }
    final profile = ConnectionProfile(
      mode: mode,
      name: device.name,
      address: device.address,
      fingerprint: device.fingerprint,
      lastConnected: DateTime.now(),
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => profile.mode == 'quality'
            ? QualityBrokerPage(
                profile: profile,
                auth: auth,
                onRefreshAuth: () => _createAuth(device, mode: mode),
              )
            : ConnectionProgressPage(
                profile: profile,
                sessionAuth: auth,
                onRefreshAuth: () => _createAuth(device, mode: mode),
                onConnected: widget.onConnected,
              ),
      ),
    );
    if (mounted) {
      await _refreshDevices();
    }
  }

  Future<void> _toggleSessions(DeviceInfo device) async {
    final api = _api;
    if (api == null) {
      return;
    }
    if (_expandedDevices.contains(device.deviceId)) {
      setState(() => _expandedDevices.remove(device.deviceId));
      return;
    }
    setState(() {
      _expandedDevices.add(device.deviceId);
      _error = null;
    });
    try {
      final sessions = await api.sessions(device.deviceId);
      if (mounted) {
        setState(() => _sessions[device.deviceId] = sessions);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = _message(error));
      }
    }
  }

  Future<void> _revokeSession(DeviceInfo device, DeviceSession session) async {
    final api = _api;
    if (api == null) {
      return;
    }
    try {
      final count = await api.revokeSessions(
        device.deviceId,
        sessionId: session.sessionId,
      );
      final sessions = await api.sessions(device.deviceId);
      if (mounted) {
        setState(() {
          _sessions[device.deviceId] = sessions;
          _notice = '已请求撤销 $count 个会话；Host 心跳会结束对应键鼠/文件任务';
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = _message(error));
      }
    }
  }

  Future<void> _revokeDevice(DeviceInfo device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤销设备'),
        content: Text(
          '撤销“${device.name}”后，新票据会被拒绝，活动会话会在 Host 心跳后终止。\n'
          '该操作不会删除 Host 本机文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (confirmed != true || _api == null) {
      return;
    }
    try {
      await _api!.revokeDevice(device.deviceId);
      final devices = await _api!.devices();
      if (mounted) {
        setState(() {
          _devices = devices;
          _notice = '设备已撤销';
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = _message(error));
      }
    }
  }

  Future<void> _registerDeviceDialog() async {
    final api = _api;
    if (api == null) {
      return;
    }
    final name = TextEditingController();
    final address = TextEditingController(
      text: Platform.isAndroid ? '192.168.1.10:24800' : '127.0.0.1:24800',
    );
    final fingerprint = TextEditingController();
    final result = await showDialog<_DeviceDraft>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('登记被控设备'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '设备名称'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: address,
                  decoration: const InputDecoration(
                    labelText: 'Host 地址',
                    hintText: 'IP:端口，例如 192.168.1.10:24800',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: fingerprint,
                  decoration: const InputDecoration(
                    labelText: 'TLS SHA-256 指纹',
                    hintText: 'Host 启动时打印的 64 位十六进制指纹',
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '设备必须先由 Host 启动并打印设备 ID/指纹。登记成功后只显示一次设备令牌，'
                    '请通过本机安全方式交给 Host（不要写入聊天或日志）。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final addressError = ConnectionProfile.validateAddress(
                address.text,
              );
              final fingerprintError = ConnectionProfile.validateFingerprint(
                fingerprint.text,
              );
              if (name.text.trim().isEmpty ||
                  addressError != null ||
                  fingerprintError != null) {
                return;
              }
              Navigator.of(context).pop(
                _DeviceDraft(
                  name: name.text.trim(),
                  address: address.text.trim(),
                  fingerprint: fingerprint.text.trim(),
                ),
              );
            },
            child: const Text('登记'),
          ),
        ],
      ),
    );
    name.dispose();
    address.dispose();
    fingerprint.dispose();
    if (result == null || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final registered = await api.registerDevice(
        name: result.name,
        address: result.address,
        fingerprint: result.fingerprint,
      );
      final devices = await api.devices();
      if (!mounted) {
        return;
      }
      setState(() {
        _devices = devices;
        _notice = '设备已登记；请把一次性设备令牌配置到 Host';
      });
      await _showDeviceToken(registered);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _showDeviceToken(RegisterDeviceResult registered) async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Host 设备令牌（仅显示一次）'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '为 ${registered.device.name} 配置 Host：\n'
                'yl-host --server-url … --device-token <令牌>\n'
                '或设置环境变量 YUANLIAN_DEVICE_TOKEN。',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 10),
              SelectableText(
                registered.deviceToken,
                style: const TextStyle(fontFamily: 'Consolas'),
              ),
              const SizedBox(height: 10),
              const Text(
                '服务端只保存令牌哈希；关闭后无法再次查看。不要把令牌写入日志或提交到仓库。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () =>
                copyText(context, registered.deviceToken, label: '设备令牌已复制'),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  String _message(Object error) {
    if (error is ServerException) {
      return error.message;
    }
    return '$error';
  }

  String _newNonce() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final account = _account;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('账号与设备', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 6),
        Text(
          '账号、配对和短时票据由独立控制服务端签发；Host 仍会二次校验并在本机确认。'
          '客户端不会自动改连公共服务。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        if (_error != null)
          _Banner(
            icon: Icons.error_outline_rounded,
            color: theme.colorScheme.error,
            text: _error!,
          ),
        if (_notice != null)
          _Banner(
            icon: Icons.info_outline_rounded,
            color: YlStatus.success,
            text: _notice!,
          ),
        if (account == null)
          _buildLogin(theme)
        else
          _buildAccount(theme, account),
      ],
    );
  }

  Widget _buildLogin(ThemeData theme) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('连接控制服务端', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _serverController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '服务端地址',
              hintText: 'https://control.example.com 或 http://127.0.0.1:18080',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('登录')),
                  ButtonSegment(value: true, label: Text('邀请注册')),
                ],
                selected: {_registerMode},
                onSelectionChanged: (value) =>
                    setState(() => _registerMode = value.first),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(labelText: '用户名'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: const InputDecoration(labelText: '密码（至少 10 位）'),
          ),
          if (_registerMode) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _inviteController,
              decoration: const InputDecoration(labelText: '邀请码'),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _signIn(register: _registerMode),
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        _registerMode
                            ? Icons.person_add_alt_1_rounded
                            : Icons.login_rounded,
                      ),
                label: Text(_busy ? '处理中' : (_registerMode ? '注册并登录' : '登录')),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: _busy
                    ? null
                    : () {
                        _serverController.text = Platform.isAndroid
                            ? 'http://10.0.2.2:18080'
                            : 'http://127.0.0.1:18080';
                      },
                child: const Text('本机服务端示例'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '服务端必须已由管理员初始化；没有服务端时，Host 只接受显式 --allow-anonymous 的开发直连。'
            '当前版本未实现 MFA/恢复码。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccount(ThemeData theme, AccountInfo account) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      account.username.isEmpty
                          ? '?'
                          : account.username[0].toUpperCase(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          account.username,
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          '${account.role} · ${_serverController.text}',
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新设备',
                    onPressed: _busy ? null : _refreshDevices,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    tooltip: '退出登录',
                    onPressed: _busy ? null : _logout,
                    icon: const Icon(Icons.logout_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _mode,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '新连接的模式（需要 v3 Host）',
                ),
                items: [
                  const DropdownMenuItem(
                    value: 'tiles',
                    child: Text('兼顾质量和流畅 · 图块'),
                  ),
                  const DropdownMenuItem(
                    value: 'flow',
                    child: Text('流畅 · 低带宽渐进图块'),
                  ),
                  if (Platform.isWindows)
                    const DropdownMenuItem(
                      value: 'quality',
                      child: Text('质量 · 视频串流 · Host 票据授权'),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _mode = value ?? 'tiles'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _registerDeviceDialog,
                    icon: const Icon(Icons.add_link_rounded, size: 18),
                    label: const Text('登记被控设备'),
                  ),
                  SizedBox(
                    width: 210,
                    child: TextField(
                      controller: _pairingController,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: '配对码',
                        hintText: '8 位',
                      ),
                      textCapitalization: TextCapitalization.characters,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy || _pairingController.text.trim().isEmpty
                        ? null
                        : _claimPairing,
                    icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                    label: const Text('领取配对'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Text('我的设备', style: theme.textTheme.titleLarge),
            const Spacer(),
            Text(
              '${_devices.length} 台',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_devices.isEmpty)
          Panel(
            child: Row(
              children: [
                const Icon(Icons.devices_other_rounded, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '还没有设备。登记 Host 后，或使用设备所有者生成的配对码领取授权。',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          )
        else
          for (final device in _devices) ...[
            _buildDeviceCard(theme, device),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  Widget _buildDeviceCard(ThemeData theme, DeviceInfo device) {
    final active = device.active;
    final sessions = _sessions[device.deviceId] ?? const <DeviceSession>[];
    final expanded = _expandedDevices.contains(device.deviceId);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.desktop_windows_rounded,
                color: active ? theme.colorScheme.primary : YlStatus.offline,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            device.name,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _StatusPill(active: active, online: device.online),
                        if (device.shared) ...[
                          const SizedBox(width: 6),
                          const _StatusPill(shared: true),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${device.address} · ${device.platform} · 所有者 ${device.owner}',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      '指纹 ${_shortFingerprint(device.fingerprint)} · '
                      '最后在线 ${_formatTime(device.lastSeen)}',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: active && !_busy ? () => _connect(device) : null,
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('连接'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _toggleSessions(device),
                icon: Icon(
                  expanded ? Icons.expand_less_rounded : Icons.podcasts_rounded,
                  size: 18,
                ),
                label: const Text('活动会话'),
              ),
              OutlinedButton.icon(
                onPressed: active && !_busy
                    ? () => _revokeDevice(device)
                    : null,
                icon: const Icon(Icons.block_rounded, size: 18),
                label: const Text('撤销设备'),
              ),
            ],
          ),
          if (expanded) ...[
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),
            if (sessions.isEmpty)
              Text(
                '当前没有活动会话',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final session in sessions)
                Row(
                  children: [
                    Icon(
                      session.revoked
                          ? Icons.hourglass_bottom_rounded
                          : Icons.lock_open_rounded,
                      size: 16,
                      color: session.revoked
                          ? YlStatus.warning
                          : YlStatus.success,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${session.user.isEmpty ? '用户 ${session.userId}' : session.user}'
                        ' · ${_permissionNames(session.permissions)}'
                        ' · 始于 ${_formatTime(session.startedAt)}'
                        '${session.revoked ? ' · 已请求撤销' : ''}',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (!session.revoked)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _revokeSession(device, session),
                        child: const Text('断开'),
                      ),
                  ],
                ),
          ],
        ],
      ),
    );
  }

  String _permissionNames(int bits) {
    final names = <String>[
      if (bits & 1 != 0) '查看',
      if (bits & 2 != 0) '控制',
      if (bits & 4 != 0) '读文件',
      if (bits & 8 != 0) '写文件',
      if (bits & 16 != 0) '删文件',
    ];
    return names.isEmpty ? '无权限' : names.join('/');
  }

  String _shortFingerprint(String fingerprint) {
    final clean = fingerprint.toUpperCase();
    return clean.length <= 16 ? clean : '${clean.substring(0, 16)}…';
  }

  String _formatTime(int epochSeconds) {
    if (epochSeconds <= 0) {
      return '从未';
    }
    return DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000)
        .toLocal()
        .toString()
        .split('.')
        .first;
  }
}

class _DeviceDraft {
  const _DeviceDraft({
    required this.name,
    required this.address,
    required this.fingerprint,
  });
  final String name;
  final String address;
  final String fingerprint;
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    this.active = false,
    this.online = false,
    this.shared = false,
  });
  final bool active;
  final bool online;
  final bool shared;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (shared) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(YlRadius.pill),
        ),
        child: Text('共享', style: theme.textTheme.labelSmall),
      );
    }
    final color = !active
        ? YlStatus.offline
        : online
        ? YlStatus.success
        : YlStatus.warning;
    final label = !active
        ? '已撤销'
        : online
        ? '在线'
        : '离线';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(YlRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 7, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
