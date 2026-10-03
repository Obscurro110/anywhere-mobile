import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
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
    if (u.startsWith('wss://')) {
      u = u.replaceFirst('wss://', 'https://');
    } else if (u.startsWith('ws://')) {
      u = u.replaceFirst('ws://', 'http://');
    }
    final i = u.indexOf('/ws');
    return i >= 0 ? u.substring(0, i) : u;
  }

  /// 自动探测一个像样的设备显示名（例如「Xiaomi 14」「Pixel 8」）。
  ///
  /// 以前默认写死 'Android Device'，所有手机都一样，电脑端设备列表里
  /// 根本分不清是哪台。改成读真实机型，用户就不用自己填了。
  static Future<String> detectDeviceName() async {
    try {
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        // 优先「品牌 + 型号」，其次单独型号
        final brand = (info.brand).trim();
        final model = (info.model).trim();
        if (brand.isNotEmpty && model.isNotEmpty) {
          final b = brand[0].toUpperCase() + brand.substring(1);
          // 型号里已含品牌就不重复拼
          if (model.toLowerCase().contains(brand.toLowerCase())) return model;
          return '$b $model';
        }
        if (model.isNotEmpty) return model;
      } else if (Platform.isIOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        final name = info.name.trim();
        if (name.isNotEmpty) return name;
        return info.utsname.machine;
      } else if (Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isLinux) {
        return Platform.localHostname;
      }
    } catch (_) {
      // 探测失败就用兜底名
    }
    return Platform.isAndroid ? 'Android Device' : Platform.localHostname;
  }

  static Future<AppConfig> load(String deviceId) async {
    final p = await SharedPreferences.getInstance();
    final def = AppConfig.defaults(deviceId);
    var name = p.getString('deviceName');
    // 首次启动 / 还留着旧的占位名 -> 自动探测一次并保存
    if (name == null || name.isEmpty || name == 'Android Device') {
      final detected = await detectDeviceName();
      if (detected.isNotEmpty && detected != 'Android Device') {
        name = detected;
        await p.setString('deviceName', detected);
      } else {
        name ??= def.deviceName;
      }
    }
    return AppConfig(
      userId: p.getString('userId') ?? def.userId,
      token: p.getString('token') ?? def.token,
      serverUrl: p.getString('serverUrl') ?? def.serverUrl,
      deviceId: p.getString('deviceId') ?? deviceId,
      deviceName: name,
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
