import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';

class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  bool _busy = false;

  Future<void> _pickAndSend() async {
    final state = context.read<AppState>();
    final result = await FilePicker.platform.pickFiles(withData: false);
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() => _busy = true);
    try {
      await state.shareFile(File(path));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件已发送到设备')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(FileMeta meta) async {
    final state = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final f = await state.downloadToDevice(meta);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存到 ${f.path}')),
        );
        await OpenFilex.open(f.path);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final files = state.receivedFiles;

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _pickAndSend,
        icon: _busy
            ? const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.upload_file),
        label: const Text('发送文件'),
      ),
      body: files.isEmpty
          ? const Center(
              child: Text(
                '暂无文件\n点击右下角发送，或接收电脑端传来的文件',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
              itemCount: files.length,
              itemBuilder: (context, i) {
                final f = files[i];
                return Card(
                  color: const Color(0xFF1B1F2B),
                  child: ListTile(
                    leading: const Icon(Icons.insert_drive_file, color: Colors.amberAccent),
                    title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${_fmtSize(f.size)} · ${f.mime}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.download),
                      onPressed: _busy ? null : () => _download(f),
                    ),
                  ),
                );
              },
            ),
    );
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
