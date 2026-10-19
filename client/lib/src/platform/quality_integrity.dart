import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

class QualityIntegrityException implements Exception {
  const QualityIntegrityException(this.message);
  final String message;
}

abstract final class QualityIntegrity {
  static const asset = 'assets/quality/moonlight-6.2.0.json';

  static Future<void> verify(String executable) async {
    final manifest = jsonDecode(await rootBundle.loadString(asset));
    if (manifest is! Map<String, dynamic> ||
        manifest['schema'] != 1 ||
        manifest['version'] != '6.2.0' ||
        manifest['component'] != 'moonlight' ||
        manifest['archive_sha256'] !=
            '6f91d268b41ed5ca8066d9d7578dc403b8db190991ff48f00b1700465f8f7ebf') {
      throw const QualityIntegrityException('客户端内置组件清单无效，请重新安装远联。');
    }
    await verifyFiles(executable, manifest['files']);
  }

  /// Shared with fixture-based tamper tests; production always loads the
  /// manifest bundled inside the app, never SHA256SUMS from an editable folder.
  static Future<void> verifyFiles(
    String executable,
    dynamic manifestFiles,
  ) async {
    final exe = File(executable);
    if (!exe.isAbsolute ||
        exe.uri.pathSegments.last.toLowerCase() != 'moonlight.exe' ||
        await FileSystemEntity.type(exe.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const QualityIntegrityException(
        '请选择本地完整组件目录中的 Moonlight.exe，不支持链接或网络路径。',
      );
    }
    final root = exe.parent.absolute;
    if ((await root.resolveSymbolicLinks()).toLowerCase() !=
        root.path.toLowerCase()) {
      throw const QualityIntegrityException('组件目录包含重解析路径，请使用独立的本地目录。');
    }
    if (manifestFiles is! List ||
        manifestFiles.isEmpty ||
        manifestFiles.length > 512) {
      throw const QualityIntegrityException('组件清单内容无效。');
    }
    final expected = <String>{};
    var total = 0;
    for (final row in manifestFiles) {
      if (row is! Map ||
          row['path'] is! String ||
          row['size'] is! int ||
          row['sha256'] is! String) {
        throw const QualityIntegrityException('组件清单条目无效。');
      }
      final name = row['path'] as String;
      final size = row['size'] as int;
      final hash = row['sha256'] as String;
      if (name.contains(RegExp(r'[\\:\x00-\x1f]')) ||
          name
              .split('/')
              .any((part) => part.isEmpty || part == '.' || part == '..') ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          !expected.add(name.toLowerCase()) ||
          size < 0 ||
          size > 256 * 1024 * 1024) {
        throw const QualityIntegrityException('组件清单路径、尺寸或摘要无效。');
      }
      total += size;
      if (total > 512 * 1024 * 1024) {
        throw const QualityIntegrityException('组件尺寸超过上限。');
      }
      final file = File(
        '${root.path}${Platform.pathSeparator}${name.replaceAll('/', Platform.pathSeparator)}',
      );
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          !((await file.resolveSymbolicLinks()).toLowerCase().startsWith(
            '${root.path.toLowerCase()}${Platform.pathSeparator}',
          ))) {
        throw QualityIntegrityException('组件缺失或包含链接：$name。请重新解压官方质量组件包。');
      }
      if (await file.length() != size ||
          (await sha256.bind(file.openRead()).first).toString() != hash) {
        throw QualityIntegrityException('组件完整性校验失败：$name。已拒绝执行，请重新解压固定版本官方包。');
      }
    }
    if (!expected.contains('moonlight.exe')) {
      throw const QualityIntegrityException('清单缺少 Moonlight.exe。');
    }
    var count = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (++count > 2048 || entity is Link) {
        throw const QualityIntegrityException('组件目录包含链接或条目过多。');
      }
      if (entity is! File) continue;
      final name = entity.path
          .substring(root.path.length + 1)
          .replaceAll('\\', '/')
          .toLowerCase();
      // Preserve pairing state; do not read, hash, log, rewrite, or package it.
      final runtime =
          name == 'moonlight.ini' ||
          name == 'moonlight game streaming project/moonlight.ini' ||
          name == 'moonlight.log' ||
          RegExp(r'^moonlight-[0-9]+\.log$').hasMatch(name);
      if (!expected.contains(name) && !runtime) {
        throw QualityIntegrityException('组件目录含清单外文件：$name。请使用独立组件目录；不会自动删除文件。');
      }
    }
  }
}
