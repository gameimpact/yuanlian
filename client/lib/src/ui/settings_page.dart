import 'dart:io';

import 'package:flutter/material.dart';

import '../models/profile.dart';
import 'design_tokens.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.profiles,
    required this.onClearProfiles,
    this.showHeader = true,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final List<ConnectionProfile> profiles;
  final Future<void> Function() onClearProfiles;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeader) ...[
            const PageHeader(
              title: '设置',
              subtitle: '本机客户端偏好。远端权限、Host 服务与账号策略不在本页修改。',
            ),
            const SizedBox(height: 20),
          ],
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionTitle('外观', subtitle: '默认跟随系统深浅主题。'),
                const SizedBox(height: 14),
                SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('跟随系统'),
                      icon: Icon(Icons.brightness_auto_rounded, size: 16),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('浅色'),
                      icon: Icon(Icons.light_mode_outlined, size: 16),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('深色'),
                      icon: Icon(Icons.dark_mode_outlined, size: 16),
                    ),
                  ],
                  selected: {themeMode},
                  onSelectionChanged: (value) =>
                      onThemeModeChanged(value.first),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionTitle(
                  '连接与本地数据',
                  subtitle: '只保存地址、名称、指纹与连接时间；不保存密码或私钥。',
                ),
                const SizedBox(height: 12),
                InfoRow(label: '已保存连接', value: '${profiles.length} 个'),
                InfoRow(label: '数据目录', value: _dataDirectory()),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: profiles.isEmpty
                      ? null
                      : () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('清除所有连接'),
                              content: const Text(
                                '将删除本机保存的地址簿条目，不会影响 Host 端、设备身份或正在进行的会话。',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(false),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(true),
                                  child: const Text('清除'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await onClearProfiles();
                          }
                        },
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('清除已保存连接'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: SectionTitle(
                        '账号、服务器与策略',
                        subtitle: '账号、设备目录、配对、短时票据和撤权已接入。',
                      ),
                    ),
                    StatusPill(
                      label: '已接入',
                      color: YlStatus.success,
                      compact: true,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '直连数据面使用 TLS 与 Host 证书指纹固定；登录后可签发绑定设备、用户和权限的'
                    '短时票据，Host 仍会本机确认并校验撤权。中继、无人值守、MFA 与策略下发仍未实现；'
                    '不要把开发版 Host 暴露到公网或用于生产远控。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionTitle('关于', subtitle: '远联 YuanLian · 跨平台远程控制'),
                const SizedBox(height: 10),
                const InfoRow(label: '客户端', value: '0.3.0 (阶段 B + 性能构建)'),
                const InfoRow(label: '协议', value: '协议 v3 · ALPN yuanlian/1'),
                const InfoRow(
                  label: 'Host 引擎',
                  value: 'WGC 主路径 + 图块 JPEG（GDI/XCap 回退）',
                ),
                const InfoRow(
                  label: '质量预览',
                  value: '视频串流 · Moonlight 6.2.0 + Sunshine（社区/非商用）',
                ),
                const InfoRow(label: '许可证', value: 'AGPL-3.0-or-later'),
                const InfoRow(
                  label: '画面路径',
                  value: 'Flutter JPEG 图块合成（native texture 未实现）',
                ),
                const SizedBox(height: 8),
                Text(
                  '直连画面仍为 JPEG 图块，后续会替换为 Rust 核心 + native texture。质量档由独立的'
                  'Moonlight 显示；账号设备入口接入 Host 票据与撤权，独立社区预览仍不受该闭环保护。',
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

  String _dataDirectory() {
    final base =
        Platform.environment['APPDATA'] ??
        Platform.environment['XDG_CONFIG_HOME'] ??
        Directory.systemTemp.path;
    return '$base${Platform.pathSeparator}YuanLian';
  }
}
