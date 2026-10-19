import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/quality_preview.dart';
import '../platform/quality_session.dart';
import '../platform/quality_integrity.dart';
import '../platform/quality_apps.dart';
import 'design_tokens.dart';
import 'widgets.dart';

/// Community-only quality preview. This page launches the official Moonlight
/// client; it must never imply that the session is covered by YuanLian tickets,
/// Host approval or central revocation.
class QualityPreviewPage extends StatefulWidget {
  const QualityPreviewPage({super.key, this.session});

  final QualitySession? session;

  @override
  State<QualityPreviewPage> createState() => _QualityPreviewPageState();
}

class _QualityPreviewPageState extends State<QualityPreviewPage> {
  final _moonlightPath = TextEditingController();
  final _host = TextEditingController();
  final _app = TextEditingController(text: 'Desktop');
  final _bitrate = TextEditingController(text: '20000');
  String _resolution = '1920x1080';
  int _fps = 60;
  String? _sunshinePath;
  bool _detected = false;
  bool _accepted = false;
  bool _confirmingLeave = false;
  String _codec = 'auto';
  String _decoder = 'auto';
  String _displayMode = 'windowed';
  bool _overlay = true;
  bool _checking = false;
  bool _querying = false;
  String? _integrityMessage;
  bool _integrityOk = false;
  String? _appsError;
  List<QualityApp> _apps = const [];
  final _appQuery = QualityAppQuery();
  late final QualitySession _session;

  bool get _working => _session.busy || _checking || _querying;

  @override
  void initState() {
    super.initState();
    _session = widget.session ?? QualitySession();
    _session.addListener(_onSessionChanged);
    _detect();
  }

  @override
  void dispose() {
    _appQuery.cancel();
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    _moonlightPath.dispose();
    _host.dispose();
    _app.dispose();
    _bitrate.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _confirmLeave() async {
    if (_confirmingLeave) return;
    if (_session.state == QualityProcessState.starting) {
      _notify('Moonlight 正在启动，请稍后结束进程再返回。');
      return;
    }
    _confirmingLeave = true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('结束本页启动的 Moonlight？'),
        content: const Text(
          '返回会关闭本页启动的外部客户端。不会关闭其他 Moonlight、'
          'Sunshine 或远端应用，也不代表中心撤权已生效。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('留在此页'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('结束并返回'),
          ),
        ],
      ),
    );
    _confirmingLeave = false;
    if (leave != true || !mounted) return;
    await _session.stop();
    if (!mounted) return;
    if (_session.busy) {
      _notify('尚未确认进程退出，请先关闭对应 Moonlight 窗口。');
      return;
    }
    // Rebuild PopScope before asking the Navigator to pop again.
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _detect() {
    final moonlight = QualityPreviewLocator.findMoonlight();
    final sunshine = QualityPreviewLocator.findSunshine();
    setState(() {
      _moonlightPath.text = moonlight ?? _moonlightPath.text;
      _sunshinePath = sunshine;
      _detected = true;
      _integrityOk = false;
      _integrityMessage = null;
      _apps = const [];
    });
  }

  void _notify(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  Future<void> _launch({bool forPairing = false}) async {
    if (!Platform.isWindows) {
      _notify('质量预览当前只随 Windows 客户端分发；Android/Linux 不能启动这个组件。');
      return;
    }
    if (_working || !_accepted) return;
    final executable = _moonlightPath.text.trim();
    if (executable.isEmpty ||
        !File(executable).isAbsolute ||
        File(executable).uri.pathSegments.last.toLowerCase() !=
            'moonlight.exe' ||
        !File(executable).existsSync()) {
      _notify('未找到 Moonlight.exe。请先解压质量预览包，或手动填写可执行文件路径。');
      return;
    }
    if (forPairing) {
      await _session.start(executable, const [], forPairing: true);
      return;
    }
    final bitrate = int.tryParse(_bitrate.text.trim());
    if (bitrate == null) {
      _notify('码率必须是整数（Kbps）。');
      return;
    }
    final config = QualityPreviewConfig(
      host: _host.text,
      app: _app.text,
      resolution: _resolution,
      fps: _fps,
      bitrateKbps: bitrate,
      videoCodec: _codec,
      videoDecoder: _decoder,
      displayMode: _displayMode,
      performanceOverlay: _overlay,
    );
    final problem = config.validate();
    if (problem != null) {
      _notify(problem);
      return;
    }
    await _session.start(executable, config.toArguments());
  }

  Future<void> _verifyComponents() async {
    if (_working) return;
    setState(() {
      _checking = true;
      _integrityMessage = null;
      _integrityOk = false;
    });
    try {
      await QualityIntegrity.verify(_moonlightPath.text.trim());
      if (mounted) {
        setState(() {
          _integrityOk = true;
          _integrityMessage = 'Moonlight 6.2.0 组件文件校验通过；启动前会重新校验。';
        });
      }
    } on QualityIntegrityException catch (error) {
      if (mounted) setState(() => _integrityMessage = error.message);
    } on Object {
      if (mounted) {
        setState(() => _integrityMessage = '无法校验组件，请检查目录访问权限与客户端内置清单。');
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _readApps() async {
    if (_working || !_accepted || !Platform.isWindows) return;
    setState(() {
      _querying = true;
      _apps = const [];
      _appsError = null;
    });
    try {
      final apps = await _appQuery.load(_moonlightPath.text.trim(), _host.text);
      if (mounted) {
        setState(() {
          _apps = apps;
          _appsError = apps.isEmpty ? 'Host 未发布可串流应用。' : null;
        });
      }
    } on QualityIntegrityException catch (error) {
      if (mounted) setState(() => _appsError = error.message);
    } on QualityAppsException catch (error) {
      if (mounted) setState(() => _appsError = error.message);
    } finally {
      if (mounted) setState(() => _querying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 720;
    return PopScope<void>(
      canPop: !_session.busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('质量模式 · 串流（Moonlight 社区预览）')),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 760;
            return SingleChildScrollView(
              padding: EdgeInsets.all(compact ? YlSpace.x4 : YlSpace.x6),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 980),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildIntro(theme),
                      const SizedBox(height: YlSpace.x4),
                      _buildSecurityNotice(theme),
                      const SizedBox(height: YlSpace.x4),
                      _buildProcessStatus(theme),
                      const SizedBox(height: YlSpace.x4),
                      if (wide)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _buildComponents(theme)),
                            const SizedBox(width: YlSpace.x4),
                            Expanded(child: _buildLaunch(theme, compact)),
                          ],
                        )
                      else ...[
                        _buildComponents(theme),
                        const SizedBox(height: YlSpace.x4),
                        _buildLaunch(theme, compact),
                      ],
                      const SizedBox(height: YlSpace.x4),
                      _buildAttribution(theme),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildIntro(ThemeData theme) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusPill(
                label: '社区预览 · 非商用',
                color: YlStatus.warning,
                icon: Icons.science_outlined,
              ),
              const Spacer(),
              Icon(
                Icons.open_in_new_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: YlSpace.x3),
          Text('质量模式使用视频串流', style: theme.textTheme.headlineMedium),
          const SizedBox(height: YlSpace.x2),
          Text(
            '质量档由上游 Moonlight 客户端与 Sunshine Host 提供：H.264/HEVC/AV1 视频、'
            '按双方能力协商编解码和低延迟串流。画面在独立 Moonlight 窗口显示；'
            '兼顾档使用图块更新，两个入口不会互相切换。',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: YlSpace.x2),
          Text(
            '远联把这条路径标为社区预览，而不是已集成、已通过安全验收的正式质量模式。'
            '不适合商用、生产环境或不受信任的网络。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSecurityNotice(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(YlSpace.x4),
      decoration: BoxDecoration(
        color: YlStatus.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(YlRadius.windowsPanel),
        border: Border.all(color: YlStatus.warning.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: YlStatus.warning,
              ),
              const SizedBox(width: YlSpace.x2),
              Expanded(
                child: Text(
                  '安全边界与远联直连模式不同',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: YlSpace.x2),
          Text(
            '配对与传输由 Moonlight/Sunshine 处理，远联尚未核验各通道加密策略。'
            '此串流不经过远联账号、短时票据、'
            'Host 本机确认或中心撤权。远联中心撤权无法结束该 Moonlight 会话，也不能对'
            'Moonlight 的读屏/输入做权限交集。请只在可信局域网内使用，并在结束后关闭'
            'Moonlight 窗口。',
            style: theme.textTheme.bodySmall,
          ),
          Material(
            type: MaterialType.transparency,
            child: CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _accepted,
              onChanged: _session.busy
                  ? null
                  : (value) => setState(() => _accepted = value ?? false),
              title: const Text('我了解：这是外部串流预览，不受远联票据与中心撤权保护。'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComponents(ThemeData theme) {
    final moonlight = _moonlightPath.text.trim();
    final moonlightExists =
        moonlight.isNotEmpty && File(moonlight).existsSync();
    final sunshine = _sunshinePath;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('1. 组件', subtitle: '质量预览包单独分发，主安装器不包含 GPL 二进制。'),
          const SizedBox(height: YlSpace.x3),
          TextField(
            controller: _moonlightPath,
            enabled: !_working,
            decoration: const InputDecoration(
              labelText: 'Moonlight.exe 路径',
              hintText: r'例如 C:\...\quality-preview\windows-x64\moonlight\Moonlight.exe',
            ),
            onChanged: (_) => setState(() {
              _integrityOk = false;
              _integrityMessage = null;
              _apps = const [];
            }),
          ),
          const SizedBox(height: YlSpace.x2),
          Wrap(
            spacing: YlSpace.x3,
            runSpacing: YlSpace.x2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _working ? null : _detect,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('重新检测'),
              ),
              StatusPill(
                label: moonlightExists ? 'Moonlight 已找到' : 'Moonlight 未找到',
                color: moonlightExists ? YlStatus.success : YlStatus.offline,
                compact: true,
              ),
              StatusPill(
                label: sunshine == null ? 'Sunshine 未找到' : 'Sunshine 已找到',
                color: sunshine == null ? YlStatus.offline : YlStatus.success,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: YlSpace.x2),
          Text(
            sunshine == null
                ? 'Sunshine 只在被控机运行，本机没有也可以控制另一台已安装 Sunshine 的电脑。'
                : '被控机组件：$sunshine',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: YlSpace.x2),
          const Text(
            '路径检测只确认文件存在；每次启动都会按客户端内置的固定版清单核对程序和依赖。'
            '文件校验不代表硬解能力或远端授权通过。',
          ),
          const SizedBox(height: YlSpace.x2),
          OutlinedButton.icon(
            onPressed: _working ? null : _verifyComponents,
            icon: const Icon(Icons.verified_outlined, size: 17),
            label: Text(_checking ? '正在校验组件…' : '校验 Moonlight 组件'),
          ),
          if (_integrityMessage != null)
            Text(
              _integrityMessage!,
              style: TextStyle(
                color: _integrityOk ? YlStatus.success : YlStatus.danger,
              ),
            ),
          if (_detected && !moonlightExists) ...[
            const SizedBox(height: YlSpace.x2),
            Text(
              '把 quality-preview 目录解压到客户端安装目录，或设置环境变量 '
              'YUANLIAN_QUALITY_PREVIEW 指向它，然后重新检测。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: YlStatus.warning,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLaunch(ThemeData theme, bool compact) {
    final wideFields = !compact;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(
            '2. 连接参数',
            subtitle: '参数原样传给官方 Moonlight CLI；不通过 shell 拼接。',
          ),
          const SizedBox(height: YlSpace.x3),
          OutlinedButton.icon(
            onPressed: Platform.isWindows && _accepted && !_working
                ? () => _launch(forPairing: true)
                : null,
            icon: const Icon(Icons.link_rounded, size: 17),
            label: const Text('打开 Moonlight 配对与应用列表'),
          ),
          const SizedBox(height: YlSpace.x2),
          const Text(
            '先在 Moonlight 中添加被控机并完成 PIN 配对，关闭窗口后可读取真实应用列表。'
            'PIN 与配对密钥不进入远联。',
          ),
          const SizedBox(height: YlSpace.x3),
          TextField(
            controller: _host,
            enabled: !_working,
            onChanged: (_) => setState(() {
              _apps = const [];
              _appsError = null;
            }),
            decoration: const InputDecoration(
              labelText: 'Sunshine Host 地址',
              hintText: '被控电脑的 IP 或主机名，如 192.168.1.10',
              helperText: '填写 Sunshine 地址；不是远联 Host 的 24800 端口。',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: YlSpace.x3),
          OutlinedButton.icon(
            onPressed: Platform.isWindows && _accepted && !_working
                ? _readApps
                : null,
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: Text(_querying ? '正在读取应用列表…' : '读取 Host 应用列表'),
          ),
          if (_querying)
            TextButton(
              onPressed: _appQuery.cancel,
              child: const Text('取消应用查询'),
            ),
          if (_appsError != null)
            Text(_appsError!, style: const TextStyle(color: YlStatus.danger)),
          if (_apps.isNotEmpty) ...[
            const SizedBox(height: YlSpace.x2),
            DropdownButtonFormField<int>(
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Host 实际发布的应用'),
              items: [
                for (final app in _apps)
                  DropdownMenuItem(
                    value: app.id,
                    child: Text(app.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _working
                  ? null
                  : (id) {
                      if (id != null) {
                        setState(
                          () => _app.text = _apps
                              .firstWhere((app) => app.id == id)
                              .name,
                        );
                      }
                    },
            ),
          ],
          const SizedBox(height: YlSpace.x3),
          TextField(
            controller: _app,
            enabled: !_working,
            decoration: const InputDecoration(
              labelText: '应用名称',
              hintText: 'Desktop',
            ),
          ),
          const SizedBox(height: YlSpace.x3),
          if (wideFields)
            Row(
              children: [
                Expanded(child: _resolutionField()),
                const SizedBox(width: YlSpace.x3),
                Expanded(child: _fpsField()),
                const SizedBox(width: YlSpace.x3),
                Expanded(child: _bitrateField()),
              ],
            )
          else ...[
            _resolutionField(),
            const SizedBox(height: YlSpace.x3),
            _fpsField(),
            const SizedBox(height: YlSpace.x3),
            _bitrateField(),
          ],
          const SizedBox(height: YlSpace.x3),
          _choiceField(
            '请求视频编码',
            _codec,
            QualityPreviewConfig.videoCodecs,
            (value) => setState(() => _codec = value),
          ),
          const SizedBox(height: YlSpace.x3),
          _choiceField(
            '请求解码方式',
            _decoder,
            QualityPreviewConfig.videoDecoders,
            (value) => setState(() => _decoder = value),
          ),
          const SizedBox(height: YlSpace.x3),
          _choiceField(
            'Moonlight 窗口',
            _displayMode,
            QualityPreviewConfig.displayModes,
            (value) => setState(() => _displayMode = value),
          ),
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _overlay,
              onChanged: _session.busy
                  ? null
                  : (value) => setState(() => _overlay = value),
              title: const Text('显示 Moonlight 实际性能浮层'),
              subtitle: const Text('参数是请求值；实际 FPS、编码与硬解以串流窗口为准。'),
            ),
          ),
          const SizedBox(height: YlSpace.x4),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: Platform.isWindows && _accepted && !_working
                  ? () => _launch()
                  : null,
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: const Text('启动 Moonlight 串流'),
            ),
          ),
          const SizedBox(height: YlSpace.x2),
          Text(
            '首次连接需要先在 Moonlight 中完成 PIN 配对；配对信息由 Moonlight 保存在'
            '它自己的配置目录，不写入远联账号或日志。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _choiceField(
    String label,
    String value,
    List<String> choices,
    ValueChanged<String> onChanged,
  ) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final item in choices)
          DropdownMenuItem(value: item, child: Text(item)),
      ],
      onChanged: _session.busy
          ? null
          : (item) {
              if (item != null) onChanged(item);
            },
    );
  }

  Widget _buildProcessStatus(ThemeData theme) {
    final label = switch (_session.state) {
      QualityProcessState.idle => '尚未启动外部客户端',
      QualityProcessState.starting => '正在启动 Moonlight…',
      QualityProcessState.running =>
        _session.pairing ? 'Moonlight 配对窗口进程运行中' : 'Moonlight 串流客户端进程运行中',
      QualityProcessState.stopping => '正在结束本页进程…',
      QualityProcessState.exited => 'Moonlight 进程已退出',
      QualityProcessState.failed => 'Moonlight 启动失败或异常退出',
    };
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.titleMedium),
          const SizedBox(height: YlSpace.x2),
          const Text(
            '进程运行不代表已配对、已连接或已出画。请在 Moonlight 窗口检查实际画面。'
            '返回前会提示结束本页进程；退出远联也会结束受管客户端。'
            '远端应用和 Sunshine 不会被关闭，中心撤权仍不覆盖此预览。',
          ),
          if (!Platform.isWindows)
            const Text('当前仅支持 Windows 外部 Moonlight；Android/Linux 此入口不可用。'),
          if (_session.pid != null) Text('本页进程 PID：${_session.pid}'),
          if (_session.exitCode != null) Text('进程退出码：${_session.exitCode}'),
          if (_session.error != null)
            Text(_session.error!, style: TextStyle(color: YlStatus.danger)),
          if (_session.busy) ...[
            const SizedBox(height: YlSpace.x2),
            OutlinedButton.icon(
              onPressed:
                  _session.pid != null &&
                      _session.state != QualityProcessState.stopping
                  ? _session.stop
                  : null,
              icon: const Icon(Icons.stop_rounded),
              label: const Text('结束本页启动的 Moonlight'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _resolutionField() {
    return DropdownButtonFormField<String>(
      initialValue: _resolution,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '分辨率'),
      items: [
        for (final value in QualityPreviewConfig.resolutions)
          DropdownMenuItem(value: value, child: Text(value)),
      ],
      onChanged: _session.busy
          ? null
          : (value) {
              if (value != null) {
                setState(() => _resolution = value);
              }
            },
    );
  }

  Widget _fpsField() {
    return DropdownButtonFormField<int>(
      initialValue: _fps,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '帧率'),
      items: [
        for (final value in QualityPreviewConfig.frameRates)
          DropdownMenuItem(value: value, child: Text('$value fps')),
      ],
      onChanged: _session.busy
          ? null
          : (value) {
              if (value != null) {
                setState(() => _fps = value);
              }
            },
    );
  }

  Widget _bitrateField() {
    return TextField(
      controller: _bitrate,
      enabled: !_session.busy,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: const InputDecoration(
        labelText: '码率 (Kbps)',
        hintText: '20000',
      ),
    );
  }

  Widget _buildAttribution(ThemeData theme) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('上游归属与许可证', subtitle: '未修改的官方发行二进制。'),
          const SizedBox(height: YlSpace.x2),
          const InfoRow(
            label: 'Moonlight',
            value: 'Moonlight-qt $moonlightPreviewVersion · GPL-3.0',
          ),
          const InfoRow(
            label: 'Sunshine',
            value: 'Sunshine $sunshinePreviewVersion · GPL-3.0',
          ),
          const InfoRow(label: 'Qt 运行库', value: 'Qt 6 · LGPL-3.0'),
          const SizedBox(height: YlSpace.x2),
          SelectableText(
            '$moonlightUpstreamUrl\n$sunshineUpstreamUrl',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: YlSpace.x2),
          Text(
            '本质量预览按项目方要求仅面向社区、非商用。GPL-3.0 本身并不禁止商业使用；'
            '如要商用，必须另行完成许可证、代码签名、审计和正式支持评估，不能沿用本预览的'
            '非商用声明。对应源码与构建说明随预览包提供。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
