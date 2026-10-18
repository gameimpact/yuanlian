import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/profile.dart';
import 'widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.profiles,
    required this.onConnect,
    required this.onRemove,
    required this.addressFocusNode,
    this.showHeader = true,
    this.compact = false,
  });

  final List<ConnectionProfile> profiles;
  final ValueChanged<ConnectionProfile> onConnect;
  final Future<void> Function(ConnectionProfile) onRemove;
  final FocusNode addressFocusNode;
  final bool showHeader;
  final bool compact;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _fingerprintController = TextEditingController();
  bool _canConnect = false;

  @override
  void initState() {
    super.initState();
    final recent = _mostRecent();
    if (recent != null) {
      _nameController.text = recent.name;
      _addressController.text = recent.address;
      _fingerprintController.text = recent.fingerprint;
    } else {
      _addressController.text =
          Platform.isAndroid ? '' : '127.0.0.1:24800';
    }
    _addressController.addListener(_onFieldChanged);
    _fingerprintController.addListener(_onFieldChanged);
    _canConnect = _isValid();
  }

  void _onFieldChanged() {
    if (!mounted) {
      return;
    }
    setState(() => _canConnect = _isValid());
  }

  bool _isValid() {
    return ConnectionProfile.validateAddress(_addressController.text) == null &&
        ConnectionProfile.validateFingerprint(
              _fingerprintController.text,
            ) ==
            null;
  }

  String _hostCommand() {
    final text = _addressController.text.trim();
    final colon = text.lastIndexOf(':');
    final host = colon < 0 ? text : text.substring(0, colon);
    final port = colon < 0 || colon == text.length - 1
        ? '24800'
        : text.substring(colon + 1);
    final local = host.isEmpty ||
        host == '127.0.0.1' ||
        host.toLowerCase() == 'localhost';
    final bindHost = local ? '127.0.0.1' : '0.0.0.0';
    return 'yl-host --listen $bindHost:$port --allow-input '
        '--file-root "C:/授权目录"';
  }

  ConnectionProfile? _mostRecent() {
    if (widget.profiles.isEmpty) {
      return null;
    }
    final sorted = [...widget.profiles]
      ..sort((a, b) {
        final at = a.lastConnected ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.lastConnected ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });
    return sorted.first;
  }

  @override
  void dispose() {
    _addressController.removeListener(_onFieldChanged);
    _fingerprintController.removeListener(_onFieldChanged);
    _nameController.dispose();
    _addressController.dispose();
    _fingerprintController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final address = _addressController.text.trim();
    final profile = ConnectionProfile(
      name: _nameController.text.trim().isEmpty
          ? 'Host $address'
          : _nameController.text.trim(),
      address: address,
      fingerprint: _fingerprintController.text.trim().toUpperCase(),
    );
    widget.onConnect(profile);
  }

  Future<void> _pasteFingerprint() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('剪贴板中没有文本'),
        ),
      );
      return;
    }
    _fingerprintController.text = text.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wide =
        !widget.compact && MediaQuery.sizeOf(context).width >= 1100;
    final connect = _buildConnectPanel(theme);
    final device = _buildThisDevicePanel(theme);
    final content = <Widget>[
      if (widget.showHeader)
        PageHeader(
          title: '连接',
          subtitle: '通过 TLS 直连 Host。填写 Host 控制台打印的地址与 SHA-256 指纹。',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFF16A34A),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '直连 · TLS',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      if (widget.showHeader) SizedBox(height: widget.compact ? 12 : 16),
      if (wide)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 5, child: connect),
            const SizedBox(width: 20),
            SizedBox(width: 320, child: device),
          ],
        )
      else
        connect,
      SizedBox(height: widget.compact ? 16 : 20),
      _buildModes(theme),
      SizedBox(height: widget.compact ? 16 : 20),
      _buildRecent(theme),
      if (!wide) ...[
        SizedBox(height: widget.compact ? 16 : 20),
        device,
      ],
      const SizedBox(height: 12),
      Text(
        '当前版本只实现画面、输入与基础单文件传输。账号、设备目录、音频、剪贴板、'
        '质量模式、Linux 与 Android 被控 Host 尚未实现，不能对外宣称完成。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    ];
    final scroll = SingleChildScrollView(
      padding: EdgeInsets.all(widget.compact ? 16 : 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: content,
      ),
    );
    if (widget.compact) {
      return scroll;
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1240),
        child: scroll,
      ),
    );
  }

  Widget _buildConnectPanel(ThemeData theme) {
    final hint = widget.compact ? '192.168.1.20:24800' : '127.0.0.1:24800';
    final connectButton = FilledButton.icon(
      onPressed: _canConnect ? _submit : null,
      icon: const Icon(Icons.play_arrow_rounded, size: 18),
      label: const Text('连接 Host'),
    );
    final fileButton = Tooltip(
      message: '仅文件连接需要独立文件授权与文件引擎，尚未实现',
      child: OutlinedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.folder_outlined, size: 17),
        label: const Text('仅传文件'),
      ),
    );
    return Panel(
      padding: EdgeInsets.all(widget.compact ? 16 : 20),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle(
              '连接其他设备',
              subtitle: 'TLS + SHA-256 指纹直连；默认端口 24800。',
              trailing: Text(
                '直连',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            SizedBox(height: widget.compact ? 14 : 16),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '连接名称（可选）',
                hintText: '例如：办公室主机',
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _addressController,
              focusNode: widget.addressFocusNode,
              decoration: InputDecoration(
                labelText: 'Host 地址',
                hintText: hint,
                prefixIcon: const Icon(Icons.dns_outlined, size: 17),
              ),
              validator: (value) =>
                  ConnectionProfile.validateAddress(value ?? ''),
              textInputAction: TextInputAction.next,
            ),
            if (widget.compact && kDebugMode)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ActionChip(
                  avatar: const Icon(Icons.developer_mode_rounded, size: 15),
                  label: const Text('使用模拟器宿主 10.0.2.2:24800'),
                  onPressed: () {
                    _addressController.text = '10.0.2.2:24800';
                  },
                ),
              ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _fingerprintController,
              decoration: InputDecoration(
                labelText: 'TLS SHA-256 指纹',
                hintText: '64 个十六进制字符，可带冒号',
                prefixIcon: const Icon(Icons.fingerprint_rounded, size: 17),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '从剪贴板粘贴',
                      onPressed: _pasteFingerprint,
                      icon: const Icon(Icons.content_paste_rounded, size: 16),
                    ),
                    if (_fingerprintController.text.isNotEmpty)
                      IconButton(
                        tooltip: '清空指纹',
                        onPressed: () {
                          _fingerprintController.clear();
                          setState(() => _canConnect = _isValid());
                        },
                        icon: const Icon(Icons.close_rounded, size: 16),
                      ),
                  ],
                ),
              ),
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 12.5),
              maxLines: 2,
              validator: (value) =>
                  ConnectionProfile.validateFingerprint(value ?? ''),
            ),
            const SizedBox(height: 16),
            if (widget.compact)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  connectButton,
                  const SizedBox(height: 8),
                  fileButton,
                ],
              )
            else
              Row(
                children: [
                  connectButton,
                  const SizedBox(width: 10),
                  fileButton,
                ],
              ),
            const SizedBox(height: 10),
            Text(
              '连接前请确认 Host 已启动，并核对控制台打印的指纹；'
              '不要连接来源不明的 Host。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThisDevicePanel(ThemeData theme) {
    final hostname = _safeHostname();
    final command = _hostCommand();
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('此设备', subtitle: '当前客户端身份与本机能力。'),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.computer_rounded,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(hostname, style: theme.textTheme.titleMedium),
                    Text(
                      '主控端 · Flutter 0.1.0',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(),
          InfoRow(label: '系统', value: _systemLabel()),
          const InfoRow(label: '角色', value: '主控查看器（M0 引擎）'),
          const InfoRow(label: '协议', value: 'yuanlian/1 · TLS 证书指纹固定'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const StatusPill(
                      label: 'Host 服务：需单独运行',
                      color: Color(0xFFD97706),
                      compact: true,
                    ),
                    IconButton(
                      tooltip: '复制 Host 启动命令',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => copyText(
                        context,
                        command,
                        label: '已复制 Host 启动命令',
                      ),
                      icon: const Icon(Icons.copy_rounded, size: 16),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SelectableText(
                  command,
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 11.5),
                ),
                const SizedBox(height: 6),
                Text(
                  '端口取自上方 Host 地址。局域网访问时 Host 绑定 0.0.0.0；'
                  '本机测试可用 127.0.0.1。Flutter 客户端不内嵌被控服务。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _systemLabel() {
    final raw = Platform.operatingSystemVersion;
    if (Platform.isWindows) {
      final buildMatch = RegExp(r'Build (\d+)').firstMatch(raw);
      final build = int.tryParse(buildMatch?.group(1) ?? '');
      final family = raw.contains('Windows 11') || (build ?? 0) >= 22000
          ? 'Windows 11'
          : 'Windows 10/Server';
      return build == null ? family : '$family · build $build';
    }
    return raw;
  }

  Widget _buildModes(ThemeData theme) {
    return Panel(
      padding: EdgeInsets.zero,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 16 : 20,
            vertical: 4,
          ),
          childrenPadding: EdgeInsets.fromLTRB(
            widget.compact ? 16 : 20,
            0,
            widget.compact ? 16 : 20,
            12,
          ),
          leading: Icon(
            Icons.grid_view_rounded,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          title: Text('模式与开发计划', style: theme.textTheme.titleMedium),
          subtitle: Text(
            '当前连接使用兼顾模式的图块引擎',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          children: [
            const Divider(),
            const _ModeRow(
              title: '兼顾质量和流畅',
              detail: '变化图块 + 静止精修；不是视频编码，也不是 Moonlight。',
              status: '当前可用',
              enabled: true,
            ),
            const Divider(),
            const _ModeRow(
              title: '质量模式',
              detail: '需要 Sunshine + moonlight-common-c；当前未安装，不会静默切换。',
              status: '未实现',
              enabled: false,
            ),
            const Divider(),
            const _ModeRow(
              title: '流畅模式',
              detail: '需要总会话带宽预算、拥塞控制与通道分账；图块引擎不能冒充。',
              status: '未实现',
              enabled: false,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecent(ThemeData theme) {
    final profiles = [...widget.profiles]
      ..sort((a, b) {
        final at = a.lastConnected ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.lastConnected ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });
    return Panel(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('最近连接', subtitle: '本地保存的连接配置，不含密码或私钥。'),
          const SizedBox(height: 10),
          if (profiles.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Row(
                children: [
                  Icon(
                    Icons.link_off_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '还没有保存的连接。成功连接一次后会出现在这里。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            for (final profile in profiles)
              _RecentTile(
                profile: profile,
                onConnect: () => widget.onConnect(profile),
                onRemove: () => widget.onRemove(profile),
              ),
        ],
      ),
    );
  }
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({
    required this.profile,
    required this.onConnect,
    required this.onRemove,
  });

  final ConnectionProfile profile;
  final VoidCallback onConnect;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fp = profile.fingerprint.replaceAll(':', '');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.desktop_windows_outlined, size: 18),
      ),
      title: Text(profile.name, style: theme.textTheme.bodyLarge),
      subtitle: Text(
        '${profile.address} · ${fp.isEmpty ? "无指纹" : "${fp.substring(0, fp.length.clamp(0, 12))}…"} · ${_relativeTime(profile.lastConnected)}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: onConnect,
            child: const Text('连接'),
          ),
          IconButton(
            tooltip: '移除保存的连接',
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('移除连接'),
                  content: Text(
                    '从地址簿移除“${profile.name}”？不会影响 Host 端或当前会话。',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('移除'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                onRemove();
              }
            },
            icon: const Icon(Icons.close_rounded, size: 16),
          ),
        ],
      ),
    );
  }
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({
    required this.title,
    required this.detail,
    required this.status,
    required this.enabled,
  });

  final String title;
  final String detail;
  final String status;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            enabled ? Icons.check_circle_outline_rounded : Icons.lock_outline_rounded,
            size: 17,
            color: enabled
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          StatusPill(
            label: status,
            color: enabled ? const Color(0xFF16A34A) : const Color(0xFF8A93A3),
            compact: true,
          ),
        ],
      ),
    );
  }
}

String _safeHostname() {
  try {
    return Platform.localHostname;
  } on Object {
    return '本机';
  }
}

String _relativeTime(DateTime? time) {
  if (time == null) {
    return '未连接';
  }
  final difference = DateTime.now().difference(time);
  if (difference.inMinutes < 1) {
    return '刚刚';
  }
  if (difference.inHours < 1) {
    return '${difference.inMinutes} 分钟前';
  }
  if (difference.inDays < 1) {
    return '${difference.inHours} 小时前';
  }
  final local = time.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, "0")}-'
      '${local.day.toString().padLeft(2, "0")} '
      '${local.hour.toString().padLeft(2, "0")}:'
      '${local.minute.toString().padLeft(2, "0")}';
}
