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
      await android?.requestNotificationsPermission();
      await android?.requestExactAlarmsPermission();
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

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
