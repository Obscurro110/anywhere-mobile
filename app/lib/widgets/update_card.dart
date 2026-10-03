import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/update_service.dart';

/// 设置页「关于 / 更新」卡片：
/// 显示手机端与电脑端版本号，并可检查 / 下载 / 安装新版本。
class UpdateCard extends StatefulWidget {
  const UpdateCard({super.key});

  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  final _svc = UpdateService();

  AppVersion _current = AppVersion.unknown;
  ReleaseInfo? _latest;
  bool _checking = false;
  bool _downloading = false;
  double _progress = 0;
  String? _error;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final v = await AppVersion.current();
    if (mounted) setState(() => _current = v);
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
      _status = '';
    });
    try {
      final latest = await _svc.fetchLatest();
      if (!mounted) return;
      setState(() {
        _latest = latest;
        _checking = false;
        _status = UpdateService.isNewer(latest, _current)
            ? '发现新版本 v${latest.versionName}'
            : '已是最新版本';
      });
      if (UpdateService.isNewer(latest, _current)) {
        _showUpdateDialog(latest);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = '检查失败：$e\n（若在墙内，可改用 GitHub 加速或手动下载）';
      });
    }
  }

  Future<void> _showUpdateDialog(ReleaseInfo info) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 v${info.versionName}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('当前版本：v${_current.versionName} (${_current.versionCode})'),
              const SizedBox(height: 8),
              Text('新版本：v${info.versionName} (${info.versionCode})'),
              if (info.humanSize.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('大小：${info.humanSize}'),
              ],
              if (info.notes.isNotEmpty) ...[
                const Divider(height: 24),
                const Text('更新内容', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(info.notes),
              ],
              const Divider(height: 24),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2418),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.amberAccent),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '安装时若提示「与已安装的应用签名不同」：\n'
                        '请先卸载本应用，再安装新版本（仅需一次）。\n'
                        '从 v1.3.1 起签名已固定，之后可直接覆盖更新。',
                        style: TextStyle(fontSize: 12, color: Colors.amberAccent),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('稍后')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('下载并安装')),
        ],
      ),
    );
    if (go == true) await _downloadAndInstall(info);
  }

  Future<void> _downloadAndInstall(ReleaseInfo info) async {
    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
      _status = '正在下载…';
    });
    try {
      final apk = await _svc.download(
        info,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _status = '下载完成，正在唤起安装器…';
      });
      await _svc.install(apk);
      if (mounted) {
        setState(() => _status = '已唤起安装器，请按提示完成安装');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = '$e';
        _status = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktopVersion = context.select<AppState, String>(
      (s) => s.capabilities.desktopVersion,
    );
    final upstream = context.select<AppState, String>(
      (s) => s.capabilities.upstreamVersion,
    );
    final hasUpdate = _latest != null && UpdateService.isNewer(_latest!, _current);

    return Card(
      color: const Color(0xFF1B1F2B),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row('手机端版本', _current.display),
            _row(
              '电脑端版本',
              desktopVersion.isEmpty
                  ? '未知（连接后自动获取）'
                  : 'v$desktopVersion${upstream.isEmpty ? '' : '（上游 $upstream）'}',
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_status, style: const TextStyle(fontSize: 12, color: Colors.lightBlueAccent)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(fontSize: 12, color: Colors.redAccent)),
            ],
            if (_downloading) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: _progress == 0 ? null : _progress),
              const SizedBox(height: 4),
              Text('${(_progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: (_checking || _downloading) ? null : _check,
                  icon: _checking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.system_update_alt),
                  label: Text(_checking ? '检查中…' : '检查更新'),
                ),
                if (hasUpdate) ...[
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: _downloading ? null : () => _downloadAndInstall(_latest!),
                    icon: const Icon(Icons.download),
                    label: Text('下载 v${_latest!.versionName}'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '更新来自 GitHub Releases（apk-latest）',
              style: TextStyle(fontSize: 11, color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 84,
              child: Text(k, style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ),
            Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
}

/// 便于外部判断：文件是否是可安装的 apk（未使用，保留给调试）。
bool looksLikeApk(File f) => f.path.toLowerCase().endsWith('.apk');
