import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../net/protocol.dart';
import '../net/remote_client.dart';
import '../platform/file_commit.dart';
import 'design_tokens.dart';
import 'widgets.dart';

class FileBrowserPage extends StatefulWidget {
  const FileBrowserPage({super.key, required this.client});

  final RemoteClient client;

  @override
  State<FileBrowserPage> createState() => FileBrowserPageState();
}

class FileBrowserPageState extends State<FileBrowserPage> {
  late final StreamSubscription<RemoteEvent> _events;
  final int _sessionTaskBase = DateTime.now().millisecondsSinceEpoch;
  int _nextTask = 1;

  String _remotePath = '';
  List<FileEntry> _remoteEntries = <FileEntry>[];
  bool _remoteLoading = false;
  String? _remoteError;
  int _remoteRequest = 0;
  Timer? _remoteTimer;

  late Directory _localDir;
  List<_LocalEntry> _localEntries = <_LocalEntry>[];
  bool _localLoading = false;
  String? _localError;

  FileEntry? _selectedRemote;
  _LocalEntry? _selectedLocal;

  _DownloadTask? _download;
  _UploadTask? _upload;
  String? _transferMessage;
  String? _transferDetail;
  bool _transferOk = false;
  double _transferProgress = 0;
  double _split = 0.5;
  bool _showRemoteMobile = true;
  bool _debugBusy = false;

  @override
  void initState() {
    super.initState();
    _localDir = _defaultLocalDirectory();
    _events = widget.client.events.listen(_onEvent);
    _loadLocal();
    if (widget.client.fileEnabled && widget.client.fileRead) {
      _loadRemote('');
    } else if (widget.client.fileEnabled) {
      _remoteError = '本次会话没有文件读取权限，只能按权限上传';
    } else {
      _remoteError = 'Host 未配置 --file-root，文件访问未开启';
    }
  }

  @override
  void dispose() {
    _remoteTimer?.cancel();
    _events.cancel();
    unawaited(_abortDownload());
    super.dispose();
  }

  /// Test-only: renders the real transfer banner without starting a network
  /// task. It does not fabricate a successful product transfer.
  @visibleForTesting
  void debugSetTransfer({
    required String message,
    required double progress,
    required bool success,
    required bool busy,
  }) {
    setState(() {
      _transferMessage = message;
      _transferProgress = progress;
      _transferOk = success;
      _download = null;
      _upload = null;
      _debugBusy = busy;
    });
  }

  /// Cancels the active download at the Host, closes the local sink and
  /// removes the temporary file. This is the same terminal path used by the
  /// cancel button, page exit and disconnect handling.
  Future<void> _abortDownload() async {
    final task = _download;
    if (task == null) {
      return;
    }
    _download = null;
    widget.client.cancelFileTask(task.taskId);
    await _cleanupDownloadTask(task, deleteTemp: true);
  }

  Future<void> _cleanupDownloadTask(
    _DownloadTask task, {
    required bool deleteTemp,
  }) async {
    try {
      await task.sink.flush();
    } on Object {
      // The sink may already be broken; closing it is still required.
    }
    try {
      await task.sink.close();
    } on Object {
      // Ignore.
    }
    if (deleteTemp) {
      try {
        await task.temp.delete();
      } on Object {
        // Already committed or removed.
      }
    }
  }

  Directory _defaultLocalDirectory() {
    const buildLocal = String.fromEnvironment('YUANLIAN_LOCAL_DIR');
    final override = Platform.environment['YUANLIAN_LOCAL_DIR'] ??
        (buildLocal.isEmpty ? null : buildLocal);
    if (override != null) {
      final directory = Directory(override);
      if (directory.existsSync()) {
        return directory;
      }
    }
    final downloads = Platform.environment['USERPROFILE'];
    if (downloads != null) {
      final candidate = Directory('$downloads${Platform.pathSeparator}Downloads');
      if (candidate.existsSync()) {
        final target = Directory(
          '${candidate.path}${Platform.pathSeparator}YuanLian',
        );
        try {
          target.createSync(recursive: true);
          return target;
        } on Object {
          return candidate;
        }
      }
      final home = Directory(downloads);
      if (home.existsSync()) {
        return home;
      }
    }
    return Directory.current;
  }

  int _allocateTask() => _sessionTaskBase + _nextTask++;

  Future<void> _loadRemote(String path) async {
    if (!widget.client.fileEnabled || !widget.client.fileRead) {
      return;
    }
    _remoteTimer?.cancel();
    final requestId = ++_remoteRequest;
    setState(() {
      _remoteLoading = true;
      _remoteError = null;
      _selectedRemote = null;
      _remotePath = path;
    });
    widget.client.requestFileList(requestId, path);
    _remoteTimer = Timer(const Duration(seconds: 10), () {
      if (mounted && requestId == _remoteRequest && _remoteLoading) {
        setState(() {
          _remoteLoading = false;
          _remoteError = '读取远端目录超时';
        });
      }
    });
  }

  Future<void> _loadLocal() async {
    setState(() {
      _localLoading = true;
      _localError = null;
      _selectedLocal = null;
    });
    try {
      final entries = <_LocalEntry>[];
      await for (final entity in _localDir.list(followLinks: false)) {
        try {
          final stat = entity.statSync();
          entries.add(
            _LocalEntry(
              name: _baseName(entity.path),
              path: entity.path,
              isDir: entity is Directory,
              size: entity is File ? stat.size : 0,
              modified: stat.modified,
            ),
          );
        } on Object {
          continue;
        }
        if (entries.length >= 2000) {
          break;
        }
      }
      entries.sort((a, b) {
        if (a.isDir != b.isDir) {
          return a.isDir ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted) {
        return;
      }
      setState(() {
        _localEntries = entries;
        _localLoading = false;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _localLoading = false;
        _localError = '读取本地目录失败：$error';
      });
    }
  }

  void _onEvent(RemoteEvent event) {
    switch (event) {
      case DirListingEvent(:final requestId, :final path, :final entries):
        if (requestId != _remoteRequest) {
          return;
        }
        _remoteTimer?.cancel();
        setState(() {
          _remoteLoading = false;
          _remoteEntries = entries;
          _remotePath = path;
        });
      case FileChunkEvent(:final taskId, :final offset, :final data):
        final download = _download;
        if (download == null || download.taskId != taskId) {
          return;
        }
        if (offset != download.received) {
          _failDownload('下载块偏移错误：期望 ${download.received}，收到 $offset');
          return;
        }
        download.sink.add(data);
        download.received += data.length;
        setState(() {
          _transferProgress =
              download.total == 0 ? 0 : download.received / download.total;
          _transferMessage =
              '下载 ${download.name}：${_formatSize(download.received)} / ${_formatSize(download.total)}';
        });
      case UploadAckEvent(:final taskId, :final received):
        final upload = _upload;
        if (upload == null || upload.taskId != taskId) {
          return;
        }
        if (received == 0 && !upload.started.isCompleted) {
          upload.started.complete();
        }
        if (received > upload.total) {
          _failUpload('Host 确认的字节数超过文件大小');
          return;
        }
        setState(() {
          _transferMessage =
              '上传 ${upload.name}：${_formatSize(received)} / ${_formatSize(upload.total)}';
        });
      case FileDoneEvent(:final taskId, :final path, :final size, :final sha256):
        if (_download?.taskId == taskId) {
          unawaited(_completeDownload(taskId, path, size, sha256));
        } else if (_upload?.taskId == taskId) {
          unawaited(_completeUpload(taskId, path, size, sha256));
        }
      case DisconnectedEvent(:final reason):
        if (_download != null) {
          _failDownload('连接断开：$reason');
        }
        if (_upload != null) {
          _failUpload('连接断开：$reason');
        }
        setState(() {
          _transferOk = false;
          _transferDetail = null;
        _transferMessage = '连接断开，文件传输已停止：$reason';
        });
      case FileErrorEvent(:final requestId, :final taskId, :final message):
        if (requestId != 0 && requestId == _remoteRequest) {
          _remoteTimer?.cancel();
          setState(() {
            _remoteLoading = false;
            _remoteError = message;
          });
        }
        if (_download?.taskId == taskId) {
          _failDownload(message, cleanup: true);
        } else if (_upload?.taskId == taskId) {
          _failUpload(message);
        }
      default:
        break;
    }
  }

  Future<void> _downloadSelected() async {
    final entry = _selectedRemote;
    if (entry == null || entry.isDir || _download != null || _upload != null) {
      return;
    }
    final destination = _uniqueLocalPath(entry.name);
    final taskId = _allocateTask();
    final temp = File('${destination.path}.part-$taskId');
    final sink = temp.openWrite();
    final task = _DownloadTask(
      taskId: taskId,
      name: entry.name,
      total: entry.size,
      destination: destination,
      temp: temp,
      sink: sink,
    );
    setState(() {
      _download = task;
      _transferDetail = null;
      _transferMessage = '开始下载 ${entry.name}';
      _transferOk = false;
      _transferProgress = 0;
    });
    widget.client.startFileDownload(taskId, entry.path);
  }

  Future<void> _completeDownload(
    int taskId,
    String path,
    int size,
    String expectedHash,
  ) async {
    final task = _download;
    if (task == null || task.taskId != taskId) {
      return;
    }
    try {
      await task.sink.flush();
      await task.sink.close();
      if (task.received != size || task.received != task.total) {
        throw StateError('收到 ${task.received} 字节，Host 声明 $size 字节');
      }
      final digest = await sha256.bind(task.temp.openRead()).first;
      final actual = digest.toString();
      if (actual.toLowerCase() != expectedHash.toLowerCase()) {
        throw StateError('SHA-256 校验失败');
      }
      final destination = _commitDownload(task.temp, task.name);
      if (!mounted) {
        return;
      }
      setState(() {
        _download = null;
        _transferOk = true;
        _transferProgress = 1;
        _transferMessage =
            '下载完成：$path → ${destination.path}\nSHA-256 $actual';
      });
      await _loadLocal();
    } on Object catch (error) {
      _failDownload('$error', cleanup: true);
    }
  }

  /// Atomically commits the verified temporary file. If the first candidate
  /// name is taken (even by a file created during the download), a numbered
  /// name is selected; an existing file is never deleted or replaced.
  File _commitDownload(File temp, String name) {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var attempt = 0; attempt < 1000; attempt++) {
      final candidateName = attempt == 0 ? name : '$stem ($attempt)$extension';
      final candidate = File(
        '${_localDir.path}${Platform.pathSeparator}$candidateName',
      );
      if (!candidate.existsSync()) {
        final status = commitNoReplace(temp, candidate);
        if (status == CommitStatus.committed) {
          return candidate;
        }
      }
    }
    throw StateError('目标目录中同名文件过多，无法选择安全的文件名');
  }

  void _failDownload(String message, {bool cleanup = true}) {
    final task = _download;
    _download = null;
    if (task != null) {
      widget.client.cancelFileTask(task.taskId);
      unawaited(_cleanupDownloadTask(task, deleteTemp: cleanup));
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _transferOk = false;
      _transferDetail = null;
      _transferMessage = '下载失败：$message';
    });
  }

  Future<void> _uploadSelected() async {
    final entry = _selectedLocal;
    if (entry == null || entry.isDir || _download != null || _upload != null) {
      return;
    }
    final name = entry.name;
    final remoteTarget =
        _remotePath.isEmpty ? name : '$_remotePath/$name';
    final existing = _remoteEntries.any((item) => item.name == name);
    var overwrite = false;
    if (existing) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('远端已存在同名文件'),
          content: Text('覆盖远端“$remoteTarget”？该操作会替换目标文件。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('覆盖'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
      overwrite = true;
    }
    final file = File(entry.path);
    final size = await file.length();
    final taskId = _allocateTask();
    final task = _UploadTask(
      taskId: taskId,
      name: name,
      total: size,
      localFile: file,
      remotePath: remoteTarget,
    );
    setState(() {
      _upload = task;
      _transferDetail = null;
      _transferMessage = '开始上传 $name';
      _transferOk = false;
      _transferProgress = 0;
    });
    widget.client.startFileUpload(taskId, remoteTarget, size, overwrite);
    unawaited(_streamUpload(task, overwrite));
  }

  Future<void> _streamUpload(_UploadTask task, bool overwrite) async {
    RandomAccessFile? reader;
    try {
      await task.started.future;
      reader = await task.localFile.open();
      var offset = 0;
      while (offset < task.total) {
        if (!mounted || _upload != task) {
          return;
        }
        final remaining = task.total - offset;
        final chunk = await reader.read(math.min(widget.client.profile.mode == 'flow' ? 2 * 1024 : 256 * 1024, remaining));
        if (chunk.isEmpty) {
          break;
        }
        widget.client.sendUploadChunk(task.taskId, offset, chunk);
        offset += chunk.length;
        setState(() {
          _transferProgress = offset / math.max(1, task.total);
          _transferMessage =
              '上传 ${task.name}：${_formatSize(offset)} / ${_formatSize(task.total)}';
        });
        await Future<void>.delayed(Duration.zero);
      }
      await reader.close();
      reader = null;
      if (!mounted || _upload != task) {
        return;
      }
      task.localHash = await sha256.bind(task.localFile.openRead()).first;
      widget.client.finishUpload(task.taskId);
    } on Object catch (error) {
      await reader?.close();
      if (_upload == task) {
        _failUpload('$error');
      }
    }
  }

  Future<void> _completeUpload(
    int taskId,
    String path,
    int size,
    String hostHash,
  ) async {
    final task = _upload;
    if (task == null || task.taskId != taskId) {
      return;
    }
    try {
      if (size != task.total) {
        throw StateError('Host 确认大小 $size 与本地 ${task.total} 不一致');
      }
      final localDigest = task.localHash ??
          await sha256.bind(task.localFile.openRead()).first;
      if (localDigest.toString().toLowerCase() != hostHash.toLowerCase()) {
        throw StateError('Host 存储后的 SHA-256 与本地不一致');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _upload = null;
        _transferOk = true;
        _transferProgress = 1;
        _transferMessage =
            '上传完成：${task.localFile.path} → $path\nSHA-256 ${localDigest.toString()}';
      });
      await _loadRemote(_remotePath);
    } on Object catch (error) {
      _failUpload('$error');
    }
  }

  void _failUpload(String message) {
    final task = _upload;
    _upload = null;
    if (task != null) {
      if (!task.started.isCompleted) {
        task.started.completeError(StateError(message));
      }
      widget.client.cancelFileTask(task.taskId);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _transferOk = false;
      _transferDetail = null;
      _transferMessage = '上传失败：$message';
    });
  }

  File _uniqueLocalPath(String name) {
    var candidate = File('${_localDir.path}${Platform.pathSeparator}$name');
    if (!candidate.existsSync()) {
      return candidate;
    }
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var index = 1; index < 1000; index++) {
      candidate = File(
        '${_localDir.path}${Platform.pathSeparator}$stem ($index)$extension',
      );
      if (!candidate.existsSync()) {
        return candidate;
      }
    }
    return File(
      '${_localDir.path}${Platform.pathSeparator}$name-${DateTime.now().microsecondsSinceEpoch}',
    );
  }

  Future<void> _goRemoteUp() async {
    if (_remotePath.isEmpty) {
      return;
    }
    final parts = _remotePath.split('/')..removeLast();
    await _loadRemote(parts.join('/'));
  }

  Future<void> _goLocalUp() async {
    final parent = _localDir.parent;
    if (parent.path == _localDir.path) {
      return;
    }
    setState(() => _localDir = parent);
    await _loadLocal();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _download != null || _upload != null || _debugBusy;
    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !mounted) {
          return;
        }
        final leave = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('传输进行中'),
            content: const Text('关闭页面会中止当前传输，是否继续？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('继续传输'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('中止并关闭'),
              ),
            ],
          ),
        );
        if (leave == true && context.mounted) {
          unawaited(_abortDownload());
          if (_upload != null) {
            widget.client.cancelFileTask(_upload!.taskId);
            _upload = null;
          }
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('文件 · ${widget.client.welcome?.hostName ?? ''}'),

        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (!widget.client.fileEnabled)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Host 未配置 --file-root，文件功能关闭。\n'
                        '在 Host 启动参数中明确授权一个目录后再连接。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                  ),
                )
              else ...[
                if (_transferMessage != null)
                  _TransferBanner(
                    message: _transferMessage!,
                    progress: _transferProgress,
                    success: _transferOk,
                    busy: busy,
                    onDetails: _transferDetail == null
                        ? null
                        : _showTransferDetail,
                  ),
                _buildFileCommandBar(theme, busy),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 800;
                      final remote = _buildRemotePane(theme, busy);
                      final local = _buildLocalPane(theme, busy);
                      if (wide) {
                        final total = constraints.maxWidth - 8;
                        final left =
                            (total * _split).clamp(280.0, total - 280.0);
                        return Row(
                          children: [
                            SizedBox(width: left, child: remote),
                            MouseRegion(
                              cursor: SystemMouseCursors.resizeLeftRight,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onHorizontalDragUpdate: (details) {
                                  final next = (left + details.delta.dx)
                                      .clamp(280.0, total - 280.0);
                                  setState(() => _split = next / total);
                                },
                                child: Container(
                                  width: 8,
                                  color:
                                      theme.colorScheme.surfaceContainerHighest,
                                  alignment: Alignment.center,
                                  child: Container(
                                    width: 1,
                                    height: 40,
                                    color: theme.colorScheme.outlineVariant,
                                  ),
                                ),
                              ),
                            ),
                            Expanded(child: local),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                            child: SizedBox(
                              width: double.infinity,
                              child: SegmentedButton<bool>(
                                segments: const [
                                  ButtonSegment(
                                    value: true,
                                    icon: Icon(Icons.cloud_outlined, size: 18),
                                    label: Text('远端'),
                                  ),
                                  ButtonSegment(
                                    value: false,
                                    icon:
                                        Icon(Icons.computer_rounded, size: 18),
                                    label: Text('本地'),
                                  ),
                                ],
                                selected: {_showRemoteMobile},
                                onSelectionChanged: (value) => setState(
                                  () => _showRemoteMobile = value.first,
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: _showRemoteMobile ? remote : local,
                          ),
                          _buildMobileFileActions(theme, busy),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFileCommandBar(ThemeData theme, bool busy) {
    final compact = MediaQuery.sizeOf(context).width < 800;
    final canUpload = widget.client.fileWrite &&
        _selectedLocal?.isDir == false &&
        !busy;
    final canDownload = widget.client.fileRead &&
        _selectedRemote?.isDir == false &&
        !busy;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.folder_special_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              widget.client.fileEnabled
                  ? '授权目录 · ${widget.client.fileRootLabel} · '
                      '${widget.client.fileRead ? '读取' : ''}'
                      '${widget.client.fileWrite ? '写入' : ''}'
                  : '未授权目录',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (!compact) ...[
            TextButton.icon(
              onPressed: canUpload ? _uploadSelected : null,
              icon: const Icon(Icons.upload_rounded, size: 16),
              label: const Text('上传'),
            ),
            const SizedBox(width: 4),
            TextButton.icon(
              onPressed: canDownload ? _downloadSelected : null,
              icon: const Icon(Icons.download_rounded, size: 16),
              label: const Text('下载'),
            ),
            const SizedBox(width: 4),
          ],
          Tooltip(
            message: '刷新远端与本地目录',
            child: IconButton(
              onPressed: busy
                  ? null
                  : () {
                      _loadRemote(_remotePath);
                      _loadLocal();
                    },
              icon: const Icon(Icons.refresh_rounded, size: 17),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileFileActions(ThemeData theme, bool busy) {
    final canUpload = widget.client.fileWrite &&
        _showRemoteMobile == false &&
        _selectedLocal?.isDir == false &&
        !busy;
    final canDownload = widget.client.fileRead &&
        _showRemoteMobile == true &&
        _selectedRemote?.isDir == false &&
        !busy;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: canUpload ? _uploadSelected : null,
              icon: const Icon(Icons.upload_rounded, size: 18),
              label: const Text('上传'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              onPressed: canDownload ? _downloadSelected : null,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('下载'),
            ),
          ),
        ],
      ),
    );
  }

  void _showTransferDetail() {
    final detail = _transferDetail;
    if (detail == null) {
      return;
    }
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('文件传输详情'),
        content: SizedBox(
          width: 460,
          child: SelectableText(detail),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => copyText(context, detail, label: '已复制传输详情'),
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

  Widget _buildRemotePane(ThemeData theme, bool busy) {
    return _Pane(
      title: '远端 · ${widget.client.fileRootLabel}',
      path: _remotePath.isEmpty ? '/' : '/$_remotePath',
      icon: Icons.cloud_outlined,
      loading: _remoteLoading,
      error: _remoteError,
      onUp: _remotePath.isEmpty ? null : _goRemoteUp,
      onRefresh: () => _loadRemote(_remotePath),
      onRetry: () => _loadRemote(_remotePath),
      child: ListView.builder(
        itemCount: _remoteEntries.length,
        itemBuilder: (context, index) {
          final entry = _remoteEntries[index];
          final selected = _selectedRemote?.path == entry.path;
          return _FileTile(
            name: entry.name,
            isDir: entry.isDir,
            size: entry.size,
            modified: DateTime.fromMillisecondsSinceEpoch(entry.modifiedMs),
            selected: selected,
            onTap: () {
              if (entry.isDir) {
                _loadRemote(entry.path);
              } else {
                setState(() => _selectedRemote = entry);
              }
            },
          );
        },
      ),
    );
  }

  Widget _buildLocalPane(ThemeData theme, bool busy) {
    return _Pane(
      title: '本地',
      path: _localDir.path,
      icon: Icons.computer_rounded,
      loading: _localLoading,
      error: _localError,
      onUp: _goLocalUp,
      onRefresh: _loadLocal,
      onRetry: _loadLocal,
      child: ListView.builder(
        itemCount: _localEntries.length,
        itemBuilder: (context, index) {
          final entry = _localEntries[index];
          final selected = _selectedLocal?.path == entry.path;
          return _FileTile(
            name: entry.name,
            isDir: entry.isDir,
            size: entry.size,
            modified: entry.modified,
            selected: selected,
            onTap: () async {
              if (entry.isDir) {
                setState(() => _localDir = Directory(entry.path));
                await _loadLocal();
              } else {
                setState(() => _selectedLocal = entry);
              }
            },
          );
        },
      ),
    );
  }
}

class _DownloadTask {
  _DownloadTask({
    required this.taskId,
    required this.name,
    required this.total,
    required this.destination,
    required this.temp,
    required this.sink,
  });
  final int taskId;
  final String name;
  final int total;
  final File destination;
  final File temp;
  final IOSink sink;
  int received = 0;
}

class _UploadTask {
  _UploadTask({
    required this.taskId,
    required this.name,
    required this.total,
    required this.localFile,
    required this.remotePath,
  });
  final int taskId;
  final String name;
  final int total;
  final File localFile;
  final String remotePath;
  final Completer<void> started = Completer<void>();
  Digest? localHash;
}

class _LocalEntry {
  const _LocalEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modified,
  });
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final DateTime modified;
}

class _Pane extends StatelessWidget {
  const _Pane({
    required this.title,
    required this.path,
    required this.icon,
    required this.loading,
    required this.error,
    required this.onUp,
    required this.onRefresh,
    required this.onRetry,
    required this.child,
  });

  final String title;
  final String path;
  final IconData icon;
  final bool loading;
  final String? error;
  final VoidCallback? onUp;
  final VoidCallback onRefresh;
  final VoidCallback onRetry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    path,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '上级目录',
                  onPressed: onUp,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                ),
              ],
            ),
          ),
          Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.45),
              border: Border(
                bottom: BorderSide(color: theme.dividerColor),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 28),
                Expanded(
                  child: Text(
                    '名称',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ),
                SizedBox(
                  width: 74,
                  child: Text(
                    '大小',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ),
                SizedBox(
                  width: 88,
                  child: Text(
                    '修改',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              error!,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextButton(onPressed: onRetry, child: const Text('重试')),
                          ],
                        ),
                      )
                    : child,
          ),
        ],
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.name,
    required this.isDir,
    required this.size,
    required this.modified,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool isDir;
  final int size;
  final DateTime modified;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.10)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              Icon(
                isDir ? Icons.folder_rounded : Icons.insert_drive_file_outlined,
                size: 19,
                color: isDir
                    ? YlStatus.folder
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              SizedBox(
                width: 74,
                child: Text(
                  isDir ? '' : _formatSize(size),
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              SizedBox(
                width: 88,
                child: Text(
                  '${modified.year}-${modified.month.toString().padLeft(2, "0")}-'
                  '${modified.day.toString().padLeft(2, "0")}',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TransferBanner extends StatelessWidget {
  const _TransferBanner({
    required this.message,
    required this.progress,
    required this.success,
    required this.busy,
    this.onDetails,
  });

  final String message;
  final double progress;
  final bool success;
  final bool busy;
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      color: success
          ? YlStatus.success.withValues(alpha: 0.10)
          : theme.colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                success
                    ? Icons.check_circle_rounded
                    : busy
                        ? Icons.sync_rounded
                        : Icons.info_outline_rounded,
                size: 16,
                color: success
                    ? YlStatus.success
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  message,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (onDetails != null)
                TextButton(
                  onPressed: onDetails,
                  child: const Text('详情'),
                ),
            ],
          ),
          if (busy) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: progress <= 0 ? null : progress.clamp(0, 1),
              minHeight: 4,
            ),
          ],
        ],
      ),
    );
  }
}

String _baseName(String path) {
  final separators = Platform.pathSeparator;
  final index = path.lastIndexOf(separators);
  return index < 0 ? path : path.substring(index + 1);
}

String _formatSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1048576).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / 1073741824).toStringAsFixed(2)} GiB';
}
