import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import 'core/app_config.dart';
import 'services/app_state.dart';
import 'screens/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final deviceId = const Uuid().v4();
  final config = await AppConfig.load(deviceId);
  final state = AppState(config);
  await state.init();
  // 版本号读一次，设置页状态卡要用
  await state.loadAppVersion();
  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const AnywhereApp(),
    ),
  );
}

class AnywhereApp extends StatelessWidget {
  const AnywhereApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Anywhere Mobile',
      debugShowCheckedModeBanner: false,
      // 中文本地化：Flutter 的系统菜单（长按文本的「复制/粘贴/全选」、
      // 日期选择器、无障碍语义等）默认是英文，必须显式声明中文，
      // 否则会话界面长按文字弹出来的是 Copy / Paste / Select all。
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B6CFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F1117),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF161923),
          elevation: 0,
        ),
      ),
      home: const HomeShell(),
    );
  }
}
