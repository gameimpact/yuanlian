import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yuanlian_client/src/platform/file_commit.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('yuanlian-commit-');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  test('commits a verified temporary file without replacing anything', () {
    final temp = File('${dir.path}${Platform.pathSeparator}download.part');
    temp.writeAsBytesSync([1, 2, 3, 4]);
    final target = File('${dir.path}${Platform.pathSeparator}download.bin');

    expect(commitNoReplace(temp, target), CommitStatus.committed);
    expect(target.readAsBytesSync(), [1, 2, 3, 4]);
    expect(temp.existsSync(), isFalse);
  });

  test('reports a conflict and leaves an existing target intact', () {
    final temp = File('${dir.path}${Platform.pathSeparator}race.part');
    temp.writeAsBytesSync([9, 9, 9]);
    final target = File('${dir.path}${Platform.pathSeparator}race.bin');
    target.writeAsBytesSync([7, 7, 7]);

    expect(commitNoReplace(temp, target), CommitStatus.targetExists);
    expect(target.readAsBytesSync(), [7, 7, 7]);
    // The temporary file is preserved so the caller can choose another name.
    expect(temp.readAsBytesSync(), [9, 9, 9]);
  });

  test('never deletes or truncates the target on a conflict', () {
    final temp = File('${dir.path}${Platform.pathSeparator}keep.part');
    temp.writeAsBytesSync([1]);
    final target = File('${dir.path}${Platform.pathSeparator}keep.txt');
    target.writeAsStringSync('old content');

    for (var attempt = 0; attempt < 3; attempt++) {
      expect(commitNoReplace(temp, target), CommitStatus.targetExists);
    }
    expect(target.readAsStringSync(), 'old content');
  });

  test('throws when the temporary file is missing', () {
    final temp = File('${dir.path}${Platform.pathSeparator}missing.part');
    final target = File('${dir.path}${Platform.pathSeparator}target.bin');
    expect(
      () => commitNoReplace(temp, target),
      throwsA(isA<FileCommitException>()),
    );
    expect(target.existsSync(), isFalse);
  });
}
