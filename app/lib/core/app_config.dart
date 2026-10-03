import 'package:shared_preferences/shared_preferences.dart';

/// Persisted connection + identity settings.
class AppConfig {
  String userId;
  String token;
  String serverUrl; // e.g. ws://1.2.3.4:8787/ws  (http scheme also accepted)
  String deviceId;
  String deviceName;
  String platform; // 'android'

  AppConfig({
    required this.userId,
    required this.token,
    required this.serverUrl,
    required this.deviceId,
    required this.deviceName,
    this.platform = 'android',
  });

  factory AppConfig.defaults(String deviceId) => AppConfig(
        userId: 'default-user',
        token: 'CHANGE_ME_TOKEN',
        serverUrl: 'ws://127.0.0.1:8787/ws',
        deviceId: deviceId,
        deviceName: 'Android Device',
      );

  /// HTTP base derived from the ws url, for file upload/download.
  String get httpBase {
    var u = serverUrl;
    if (u.startsWith('wss://')) u = u.replaceFirst('wss://', 'https://');
    else if (u.startsWith('ws://')) u = u.replaceFirst('ws://', 'http://');
    final i = u.indexOf('/ws');
    return i >= 0 ? u.substring(0, i) : u;
  }

  static Future<AppConfig> load(String deviceId) async {
    final p = await SharedPreferences.getInstance();
    final def = AppConfig.defaults(deviceId);
    return AppConfig(
      userId: p.getString('userId') ?? def.userId,
      token: p.getString('token') ?? def.token,
      serverUrl: p.getString('serverUrl') ?? def.serverUrl,
      deviceId: p.getString('deviceId') ?? deviceId,
      deviceName: p.getString('deviceName') ?? def.deviceName,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('userId', userId);
    await p.setString('token', token);
    await p.setString('serverUrl', serverUrl);
    await p.setString('deviceId', deviceId);
    await p.setString('deviceName', deviceName);
  }
}
