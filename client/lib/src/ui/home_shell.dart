import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/profile.dart';
import '../models/session_auth.dart';
import 'account_page.dart';
import 'quality_broker_page.dart';
import 'connection_progress_page.dart';
import 'design_tokens.dart';
import 'home_page.dart';
import 'settings_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
    this.initialConnection,
    this.initialSessionAuth,
    this.inputSelfTest = false,
    this.autoOpenFiles = false,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final ConnectionProfile? initialConnection;
  final SessionAuth? initialSessionAuth;
  final bool inputSelfTest;
  final bool autoOpenFiles;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _selected = 0;
  bool _loading = true;
  bool _autoConnected = false;
  List<ConnectionProfile> _profiles = <ConnectionProfile>[];
  final FocusNode _addressFocus = FocusNode(debugLabel: 'host-address');

  bool _usesWindowsShell(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  @override
  void dispose() {
    _addressFocus.dispose();
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    final profiles = await LocalStore.loadProfiles();
    if (!mounted) {
      return;
    }
    setState(() {
      _profiles = profiles;
      _loading = false;
    });
    final initial = widget.initialConnection;
    if (initial != null && !_autoConnected) {
      _autoConnected = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _openConnection(initial);
        }
      });
    }
  }

  Future<void> _remember(ConnectionProfile profile) async {
    final updated = <ConnectionProfile>[
      profile.copyWith(lastConnected: DateTime.now()),
      ..._profiles.where(
        (item) =>
            !(item.address == profile.address &&
                item.fingerprint == profile.fingerprint),
      ),
    ].take(20).toList();
    setState(() => _profiles = updated);
    await LocalStore.saveProfiles(updated);
  }

  Future<void> _removeProfile(ConnectionProfile profile) async {
    final updated = _profiles
        .where(
          (item) =>
              !(item.address == profile.address &&
                  item.fingerprint == profile.fingerprint),
        )
        .toList();
    setState(() => _profiles = updated);
    await LocalStore.saveProfiles(updated);
  }

  Future<void> _openConnection(ConnectionProfile profile) async {
    if (profile.mode == 'quality' && widget.initialSessionAuth == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('质量串流需要账号签发的 quality 票据，请从账号与设备页连接')),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => profile.mode == 'quality'
            ? QualityBrokerPage(
                profile: profile,
                auth: widget.initialSessionAuth!,
                autoStart: true,
              )
            : ConnectionProgressPage(
                profile: profile,
                sessionAuth: widget.initialSessionAuth,
                onConnected: _remember,
                inputSelfTest: widget.inputSelfTest,
                autoOpenFiles: widget.autoOpenFiles,
              ),
      ),
    );
  }

  void _openPage(int index) => setState(() => _selected = index);

  void _focusAddress() {
    _openPage(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _addressFocus.requestFocus();
      }
    });
  }

  void _showUnavailable(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$feature需要服务端或文件专项能力，当前开发版尚未接入；不会用演示数据冒充。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('开发版说明'),
        content: const SizedBox(
          width: 460,
          child: Text(
            '当前为阶段 B 开发版。\n\n'
            '· Windows/Android 客户端通过 TLS + SHA-256 指纹连接 Host；\n'
            '· 账号登录、设备目录、配对、短时票据与中心撤权已接入；Host 仍会本机确认；\n'
            '· 未登录的匿名直连必须由 Host 显式 --allow-anonymous，默认拒绝；\n'
            '· 画面使用变化图块（Dart 合成），不是原生纹理/Moonlight 视频；\n'
            '· 文件支持单文件上传/下载与 SHA-256 校验；\n'
            '· 质量模式使用视频串流：账号与设备入口接入 Host 票据和撤权；独立社区预览不受该闭环保护；\n'
            '· MFA/恢复码、中继、Linux、Android 被控 Host 未实现。\n\n'
            '不要把开发版 Host 暴露到公网。',
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final isWindows = _usesWindowsShell(context);
    final home = HomePage(
      onOpenAccount: () => _openPage(1),
      profiles: _profiles,
      onConnect: _openConnection,
      onRemove: _removeProfile,
      addressFocusNode: _addressFocus,
      showHeader: isWindows,
      compact: !isWindows,
    );
    final account = AccountPage(onConnected: _remember);
    final settings = SettingsPage(
      themeMode: widget.themeMode,
      onThemeModeChanged: widget.onThemeModeChanged,
      profiles: _profiles,
      showHeader: isWindows,
      onClearProfiles: () async {
        setState(() => _profiles = <ConnectionProfile>[]);
        await LocalStore.saveProfiles(<ConnectionProfile>[]);
      },
    );
    final pages = <Widget>[home, account, settings];
    final title = switch (_selected) {
      0 => '连接',
      1 => '账号与设备',
      _ => '设置',
    };

    if (isWindows) {
      return CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
              _openPage(2),
          const SingleActivator(LogicalKeyboardKey.keyL, control: true):
              _focusAddress,
          const SingleActivator(LogicalKeyboardKey.f1): _showHelp,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final expanded = constraints.maxWidth >= 1040;
                  return Row(
                    children: [
                      _WindowsSidebar(
                        expanded: expanded,
                        selected: _selected,
                        onSelect: _openPage,
                        onUnavailable: _showUnavailable,
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: Column(
                          children: [
                            _WindowsCommandBar(title: title, onHelp: _showHelp),
                            Expanded(
                              child: IndexedStack(
                                index: _selected,
                                children: pages,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: '帮助',
            onPressed: _showHelp,
            icon: const Icon(Icons.help_outline_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: IndexedStack(index: _selected, children: pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selected,
        onDestinationSelected: _openPage,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.link_outlined),
            selectedIcon: Icon(Icons.link_rounded),
            label: '连接',
          ),
          NavigationDestination(
            icon: Icon(Icons.devices_other_outlined),
            selectedIcon: Icon(Icons.devices_other_rounded),
            label: '设备',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

class _WindowsSidebar extends StatelessWidget {
  const _WindowsSidebar({
    required this.expanded,
    required this.selected,
    required this.onSelect,
    required this.onUnavailable,
  });

  final bool expanded;
  final int selected;
  final ValueChanged<int> onSelect;
  final ValueChanged<String> onUnavailable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = <_WindowsNavItem>[
      const _WindowsNavItem('连接', Icons.link_rounded, page: 0),
      const _WindowsNavItem('账号与设备', Icons.devices_other_rounded, page: 1),
      const _WindowsNavItem('文件传输', Icons.folder_open_rounded, enabled: false),
      const _WindowsNavItem('活动记录', Icons.history_rounded, enabled: false),
      const _WindowsNavItem('设置', Icons.settings_outlined, page: 2),
    ];

    return Container(
      width: expanded ? 240 : 64,
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 52,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: expanded ? 16 : 12),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '远',
                      style: TextStyle(
                        color: theme.colorScheme.onPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (expanded) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '远联',
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      'YuanLian',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const Divider(),
          const SizedBox(height: 6),
          for (final item in items)
            _WindowsNavTile(
              item: item,
              expanded: expanded,
              selected: item.page == selected,
              onTap: item.enabled
                  ? () => onSelect(item.page!)
                  : () => onUnavailable(item.label),
            ),
          const Spacer(),
          Padding(
            padding: EdgeInsets.all(expanded ? 14 : 8),
            child: expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: YlStatus.success,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('直连模式', style: theme.textTheme.bodySmall),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '阶段 B 开发版 · 协议 v3',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  )
                : const Tooltip(
                    message: '直连模式 · 阶段 B 开发版',
                    child: Icon(Icons.circle, size: 8, color: YlStatus.success),
                  ),
          ),
        ],
      ),
    );
  }
}

class _WindowsNavItem {
  const _WindowsNavItem(
    this.label,
    this.icon, {
    this.enabled = true,
    this.page,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final int? page;
}

class _WindowsNavTile extends StatelessWidget {
  const _WindowsNavTile({
    required this.item,
    required this.expanded,
    required this.selected,
    required this.onTap,
  });

  final _WindowsNavItem item;
  final bool expanded;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = selected
        ? theme.colorScheme.primary
        : item.enabled
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);
    final tile = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Container(
            height: 38,
            padding: EdgeInsets.symmetric(horizontal: expanded ? 10 : 0),
            decoration: BoxDecoration(
              border: selected
                  ? Border(
                      left: BorderSide(
                        color: theme.colorScheme.primary,
                        width: 3,
                      ),
                    )
                  : null,
            ),
            child: Row(
              mainAxisAlignment: expanded
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: [
                Icon(item.icon, size: 16, color: foreground),
                if (expanded) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item.label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (!item.enabled)
                    Text(
                      '未接入',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.55,
                        ),
                        fontSize: 11,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return expanded ? tile : Tooltip(message: item.label, child: tile);
  }
}

class _WindowsCommandBar extends StatelessWidget {
  const _WindowsCommandBar({required this.title, required this.onHelp});
  final String title;
  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Text(
            '工作台',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '/',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(title, style: theme.textTheme.bodyMedium),
          const Spacer(),
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: YlStatus.success,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'TLS 直连',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Tooltip(
            message: 'F1 帮助 · Ctrl+, 设置 · Ctrl+L 聚焦地址',
            child: IconButton(
              onPressed: onHelp,
              icon: const Icon(Icons.help_outline_rounded, size: 17),
            ),
          ),
        ],
      ),
    );
  }
}
