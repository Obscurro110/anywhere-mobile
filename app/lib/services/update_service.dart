import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// 当前安装的 App 版本。
class AppVersion {
  final String versionName;
  final int versionCode;
  const AppVersion({required this.versionName, required this.versionCode});

  String get display => 'v$versionName ($versionCode)';

  static const unknown = AppVersion(versionName: '?', versionCode: 0);

  static Future<AppVersion> current() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return AppVersion(
        versionName: info.version.isEmpty ? '?' : info.version,
        versionCode: int.tryParse(info.buildNumber) ?? 0,
      );
    } catch (e) {
      debugPrint('[UpdateService] read version failed: $e');
      return unknown;
    }
  }
}

/// 远端发布信息（由 CI 生成并挂在 Release apk-latest 上）。
class ReleaseInfo {
  final String versionName;
  final int versionCode;
  final String notes;
  final String url;
  final String sha256;
  final int size;
  final String builtAt;

  ReleaseInfo({
    required this.versionName,
    required this.versionCode,
    this.notes = '',
    required this.url,
    this.sha256 = '',
    this.size = 0,
    this.builtAt = '',
  });

  factory ReleaseInfo.fromJson(Map<String, dynamic> j) => ReleaseInfo(
        versionName: j['versionName'] as String? ?? '',
        versionCode: (j['versionCode'] as num?)?.toInt() ?? 0,
        notes: j['notes'] as String? ?? '',
        // apkUrl 是明确指向该版本 Release 的下载地址；
        // 老格式只有 url，兜底用（2026-10 起 apk-latest 不再挂 APK）
        url: (j['apkUrl'] as String?)?.isNotEmpty == true
            ? j['apkUrl'] as String
            : (j['url'] as String? ?? ''),
        sha256: j['sha256'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        builtAt: j['builtAt'] as String? ?? '',
      );

  String get humanSize {
    if (size <= 0) return '';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// 检查 / 下载 / 安装更新。
///
/// 版本号来源：仓库根 `version.json` -> CI 构建 ->
/// 发布到 Release `apk-latest` 的 `version.json` 资产。
class UpdateService {
  UpdateService({
    this.owner = 'Obscurro110',
    this.repo = 'anywhere-mobile',
    this.releaseTag = 'apk-latest',
  });

  final String owner;
  final String repo;
  final String releaseTag;

  /// 直链（release 资产）
  String get _versionJsonUrl =>
      'https://github.com/$owner/$repo/releases/download/$releaseTag/version.json';

  /// API 兜底：apk-latest 只作指针（无 APK），真正带 APK 的是各版本 Release，
  /// 所以兜底时查「最新正式 Release」。
  String get _apiUrl => 'https://api.github.com/repos/$owner/$repo/releases/latest';

  static const _timeout = Duration(seconds: 20);

  /// 拉取远端最新版本信息。失败抛异常。
  Future<ReleaseInfo> fetchLatest() async {
    // 1) 先试直链（最快）
    try {
      final resp = await http.get(Uri.parse(_versionJsonUrl)).timeout(_timeout);
      if (resp.statusCode == 200) {
        final j = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
        final info = ReleaseInfo.fromJson(j);
        if (info.versionName.isNotEmpty) return info;
      }
    } catch (e) {
      debugPrint('[UpdateService] direct version.json failed: $e');
    }

    // 2) 兜底：GitHub API 从「最新正式 Release」的资产里找
    final resp = await http
        .get(Uri.parse(_apiUrl), headers: {'Accept': 'application/vnd.github+json'})
        .timeout(_timeout);
    if (resp.statusCode != 200) {
      throw Exception('无法获取版本信息（HTTP ${resp.statusCode}）');
    }
    final j = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final tag = (j['tag_name'] as String?) ?? '';

    // 2a) 优先读该 Release 上的 version.json —— 里面有 sha256，
    //     缺了它下载会被安全校验拒绝（见 download()）。
    if (tag.isNotEmpty) {
      try {
        final vj = await http
            .get(Uri.parse(
                'https://github.com/$owner/$repo/releases/download/$tag/version.json'))
            .timeout(_timeout);
        if (vj.statusCode == 200) {
          final info = ReleaseInfo.fromJson(
              jsonDecode(utf8.decode(vj.bodyBytes)) as Map<String, dynamic>);
          if (info.versionName.isNotEmpty) return info;
        }
      } catch (e) {
        debugPrint('[UpdateService] fallback version.json failed: $e');
      }
    }

    final assets = (j['assets'] as List?) ?? [];
    String url = '';
    int size = 0;
    // 优先精确匹配 anywhere-mobile-<版本>.apk，其次任意 anywhere-mobile*.apk
    final verMatch = RegExp(r'v?(\d+\.\d+\.\d+)').firstMatch(tag);
    final ver = verMatch?.group(1) ?? '';
    Map<String, dynamic>? fallback;
    for (final a in assets) {
      final m = (a as Map).cast<String, dynamic>();
      final n = m['name'] as String? ?? '';
      if (!n.endsWith('.apk')) continue;
      fallback ??= m;
      if (ver.isNotEmpty && n == 'anywhere-mobile-$ver.apk') {
        url = m['browser_download_url'] as String? ?? '';
        size = (m['size'] as num?)?.toInt() ?? 0;
        break;
      }
    }
    if (url.isEmpty && fallback != null) {
      url = fallback['browser_download_url'] as String? ?? '';
      size = (fallback['size'] as num?)?.toInt() ?? 0;
    }
    // 版本号从 tag 或 name 里粗解析
    final name = (j['name'] as String?) ?? tag;
    final match = RegExp(r'v?(\d+\.\d+\.\d+)').firstMatch(name);
    return ReleaseInfo(
      versionName: match?.group(1) ?? tag,
      versionCode: 0, // 未知 -> 用版本名比较
      url: url,
      size: size,
    );
  }

  /// 是否有新版本。
  static bool isNewer(ReleaseInfo remote, AppVersion current) {
    if (remote.versionCode > 0 && current.versionCode > 0) {
      if (remote.versionCode != current.versionCode) {
        return remote.versionCode > current.versionCode;
      }
    }
    return compareSemver(remote.versionName, current.versionName) > 0;
  }

  /// 语义化版本比较：a > b 返回 1，相等 0，小于 -1。
  static int compareSemver(String a, String b) {
    List<int> parse(String s) {
      final core = s.split('+').first;
      final parts = core.split('.');
      return List.generate(3, (i) {
        if (i >= parts.length) return 0;
        return int.tryParse(RegExp(r'\d+').stringMatch(parts[i]) ?? '') ?? 0;
      });
    }

    final x = parse(a);
    final y = parse(b);
    for (var i = 0; i < 3; i++) {
      if (x[i] != y[i]) return x[i] > y[i] ? 1 : -1;
    }
    return 0;
  }

  /// 下载 APK 到应用私有目录，返回文件路径。
  Future<File> download(ReleaseInfo info, {void Function(double)? onProgress}) async {
    if (info.url.isEmpty) throw Exception('下载地址为空');
    final dir = await getApplicationSupportDirectory();
    final apkDir = Directory('${dir.path}/updates');
    if (!await apkDir.exists()) await apkDir.create(recursive: true);
    final path = '${apkDir.path}/anywhere-mobile-${info.versionName}.apk';
    final file = File(path);

    final req = http.Request('GET', Uri.parse(info.url));
    req.headers['Accept'] = 'application/octet-stream';
    final streamed = await req.send().timeout(_timeout);
    if (streamed.statusCode != 200) {
      throw Exception('下载失败（HTTP ${streamed.statusCode}）');
    }
    final total = streamed.contentLength ?? info.size;
    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in streamed.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && onProgress != null) {
          onProgress(received / total);
        }
      }
    } finally {
      await sink.close();
    }

    // ⚠️ 安全：必须校验 sha256。
    // 否则中继/GitHub 账号/镜像任一被攻破，都能下发一个被篡改的 APK，
    // 而本应用会直接把它交给系统安装器 —— 等于手机端远程代码执行。
    // sha256 由 CI 生成并随 Release 一起发布；这里为空时退化为「拒绝安装」，
    // 宁可用不了也不装来路不明的包。
    if (info.sha256.isEmpty) {
      try {
        await file.delete();
      } catch (_) {}
      throw Exception('安装包缺少 sha256 校验值，已拒绝下载（请更新到带校验的版本）');
    }
    final actual = await _sha256OfFile(file);
    if (actual.toLowerCase() != info.sha256.trim().toLowerCase()) {
      try {
        await file.delete();
      } catch (_) {}
      throw Exception('安装包校验失败（可能被篡改），已删除。期望 ${info.sha256}，实际 $actual');
    }

    return file;
  }

  /// 流式计算文件 sha256（避免把整个 APK 读进内存）。
  static Future<String> _sha256OfFile(File file) async {
    final sink = _DigestAccumulator();
    final input = sha256.startChunkedConversion(sink);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return sink.value.toString();
  }

  /// 唤起系统安装器。
  Future<void> install(File apk) async {
    final res = await OpenFilex.open(
      apk.path,
      type: 'application/vnd.android.package-archive',
    );
    if (res.type != ResultType.done) {
      throw Exception(
        '无法唤起安装器（${res.message}）。请到「系统设置 → 允许本应用安装未知应用」后重试，'
        '或手动打开：${apk.path}',
      );
    }
  }
}

/// 只收集最后一个 Digest 的 Sink（避免额外引入 package:convert）。
class _DigestAccumulator implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
