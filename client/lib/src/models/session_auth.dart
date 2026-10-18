/// Short-lived ticket issued by the control plane for one connection attempt.
/// The nonce is generated locally and its hash is signed into the ticket, so a
/// stolen ticket cannot be replayed without the nonce.
class SessionAuth {
  const SessionAuth({
    required this.ticket,
    required this.nonce,
    required this.sessionId,
    required this.account,
    required this.permissions,
    required this.expiresAt,
  });

  final String ticket;
  final String nonce;
  final String sessionId;
  final String account;
  final int permissions;
  final int expiresAt;

  String get permissionLabel {
    final names = <String>[
      if (permissions & 1 != 0) '查看',
      if (permissions & 2 != 0) '控制',
      if (permissions & 4 != 0) '读取文件',
      if (permissions & 8 != 0) '写入文件',
      if (permissions & 16 != 0) '删除文件',
    ];
    if (names.isEmpty) {
      return '由 Host 确认';
    }
    return names.join('、');
  }
}
