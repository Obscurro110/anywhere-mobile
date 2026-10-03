import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper around flutter_local_notifications.
///
/// The relay pushes chat/notification frames over the WebSocket; when the app
/// is alive (foreground or background service) we surface them as local
/// notifications. No Firebase / Google services required.
class NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const _channelId = 'anywhere_relay';
  static const _channelName = 'Anywhere';
  static const _channelDesc = 'Messages and notifications from Anywhere Desktop';

  /// 只初始化插件与渠道，**不申请任何权限**。
  ///
  /// 这里以前顺手调了 `requestExactAlarmsPermission()`，那是给「到点必须
  /// 精确触发」的本地定时提醒用的（Android 12+ 会跳到系统「闹钟和提醒」
  /// 设置页）。本应用的通知全部来自 WebSocket 实时推送，不需要精确闹钟，
  /// 所以那个权限完全没必要 —— 去掉后就不会每次开 App 都弹了。
  Future<void> init() async {
    if (_ready) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const init = InitializationSettings(android: androidInit);
    try {
      await _plugin.initialize(init);
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDesc,
        importance: Importance.high,
      ));
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  /// 申请通知权限。**由用户主动开启通知开关时才调用**，不在启动时打扰。
  ///
  /// 返回是否已获得授权。
  Future<bool> requestPermission() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await android?.requestNotificationsPermission();
      return granted ?? true;
    } catch (_) {
      return false;
    }
  }

  /// 当前是否已有通知权限（不弹窗，只查询）。
  Future<bool> hasPermission() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final enabled = await android?.areNotificationsEnabled();
      return enabled ?? false;
    } catch (_) {
      return false;
    }
  }

  bool get isReady => _ready;

  Future<void> show(String title, String body, {int id = 0}) async {
    if (!_ready) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(''),
      ),
    );
    try {
      await _plugin.show(id, title, body, details);
    } catch (_) {}
  }
}
