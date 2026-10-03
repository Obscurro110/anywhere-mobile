import 'package:flutter/material.dart';
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
