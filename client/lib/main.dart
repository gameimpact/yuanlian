import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/models/profile.dart';
import 'src/models/session_auth.dart';
import 'src/ui/home_shell.dart';
import 'src/ui/theme.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.android) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  final settings = await LocalStore.loadSettings();
  final themeMode = switch (settings['themeMode']) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
  const buildAddress = String.fromEnvironment('YUANLIAN_AUTO_ADDRESS');
  const buildFingerprint = String.fromEnvironment('YUANLIAN_AUTO_FINGERPRINT');
  const buildName = String.fromEnvironment('YUANLIAN_AUTO_NAME');
  const buildOpenFiles = bool.fromEnvironment('YUANLIAN_AUTO_OPEN_FILES');
  String? address = buildAddress.isEmpty ? null : buildAddress;
  String? fingerprint = buildFingerprint.isEmpty ? null : buildFingerprint;
  String? name = buildName.isEmpty ? null : buildName;
  var inputSelfTest = const bool.fromEnvironment('YUANLIAN_INPUT_SELF_TEST');
  var autoOpenFiles = buildOpenFiles;
  String? ticket = Platform.environment['YUANLIAN_SESSION_TICKET'];
  var mode = 'tiles';
  String nonce = '';
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--auto-connect-address':
        if (i + 1 < args.length) {
          address = args[++i];
        }
      case '--auto-connect-fingerprint':
        if (i + 1 < args.length) {
          fingerprint = args[++i];
        }
      case '--auto-connect-mode':
        if (i + 1 < args.length &&
            ['tiles', 'flow', 'quality'].contains(args[i + 1])) {
          mode = args[++i];
        }
      case '--auto-connect-name':
        if (i + 1 < args.length) {
          name = args[++i];
        }
      case '--auto-connect-ticket':
        if (i + 1 < args.length) {
          ticket = args[++i];
        }
      case '--auto-connect-nonce':
        if (i + 1 < args.length) {
          nonce = args[++i];
        }
      case '--input-self-test':
        inputSelfTest = true;
      case '--auto-open-files':
        autoOpenFiles = true;
    }
  }
  final initialConnection = address != null && fingerprint != null
      ? ConnectionProfile(
          name: (name ?? '').trim().isEmpty ? '自动连接' : name!,
          address: address,
          mode: mode,
          fingerprint: fingerprint.toUpperCase(),
        )
      : null;
  final initialAuth = ticket == null
      ? null
      : SessionAuth(
          ticket: ticket,
          nonce: nonce,
          sessionId: 'auto',
          account: '票据自动连接',
          permissions: 0,
          expiresAt: 0,
        );
  runApp(
    YuanLianApp(
      initialThemeMode: themeMode,
      initialConnection: initialConnection,
      initialSessionAuth: initialAuth,
      inputSelfTest: inputSelfTest,
      autoOpenFiles: autoOpenFiles,
    ),
  );
}

class YuanLianApp extends StatefulWidget {
  const YuanLianApp({
    super.key,
    required this.initialThemeMode,
    this.initialConnection,
    this.initialSessionAuth,
    this.inputSelfTest = false,
    this.autoOpenFiles = false,
  });
  final ThemeMode initialThemeMode;
  final ConnectionProfile? initialConnection;
  final SessionAuth? initialSessionAuth;
  final bool inputSelfTest;
  final bool autoOpenFiles;

  @override
  State<YuanLianApp> createState() => _YuanLianAppState();
}

class _YuanLianAppState extends State<YuanLianApp> {
  late ThemeMode _themeMode = widget.initialThemeMode;

  Future<void> _setThemeMode(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    final settings = await LocalStore.loadSettings();
    settings['themeMode'] = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await LocalStore.saveSettings(settings);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '远联 YuanLian',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
            statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
            statusBarBrightness: dark ? Brightness.dark : Brightness.light,
            systemNavigationBarIconBrightness: dark
                ? Brightness.light
                : Brightness.dark,
            systemNavigationBarContrastEnforced: false,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: HomeShell(
        themeMode: _themeMode,
        onThemeModeChanged: _setThemeMode,
        initialConnection: widget.initialConnection,
        initialSessionAuth: widget.initialSessionAuth,
        inputSelfTest: widget.inputSelfTest,
        autoOpenFiles: widget.autoOpenFiles,
      ),
    );
  }
}
