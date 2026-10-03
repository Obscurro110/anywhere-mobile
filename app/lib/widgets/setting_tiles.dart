import 'package:flutter/material.dart';

/// 设置页的通用排版组件 —— 统一各分组的视觉规格。
///
/// 用法：
///   const SettingGroupTitle('与电脑端'),
///   SettingCard(children: [ SettingTile(...), SettingTile(...) ]),
class SettingGroupTitle extends StatelessWidget {
  final String text;
  const SettingGroupTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Colors.white54,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// 一张圆角卡片，把同组的 SettingTile 包起来，自动加分隔线。
class SettingCard extends StatelessWidget {
  final List<Widget> children;
  const SettingCard({required this.children, super.key});

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        items.add(const Divider(height: 1, indent: 56, color: Color(0xFF262B38)));
      }
      items.add(children[i]);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1F2B),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: items),
    );
  }
}

/// 设置项：图标 + 标题 (+ 右侧值/副标题) + 箭头。
class SettingTile extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  const SettingTile({
    required this.icon,
    required this.title,
    this.iconColor,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: const Color(0xFF232838),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 18, color: iconColor ?? Colors.white70),
      ),
      title: Text(title, style: const TextStyle(fontSize: 14.5)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!,
              style: const TextStyle(fontSize: 12, color: Colors.white38)),
      trailing: trailing ??
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (value != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 130),
                  child: Text(
                    value!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 13, color: Colors.white54),
                  ),
                ),
              if (onTap != null && value == null)
                const Icon(Icons.chevron_right, size: 20, color: Colors.white24),
              if (onTap != null && value != null)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(Icons.chevron_right, size: 20, color: Colors.white24),
                ),
            ],
          ),
    );
  }
}
