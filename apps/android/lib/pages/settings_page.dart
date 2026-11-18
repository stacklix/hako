import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../platform/doppel_platform.dart';
import '../widgets/common_widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.permissions,
    required this.onSnapshotChanged,
  });

  final PlatformPermissions permissions;
  final ValueChanged<PlatformSnapshot> onSnapshotChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _autoAnswer = false;
  late PlatformPermissions _permissions;

  @override
  void initState() {
    super.initState();
    _permissions = widget.permissions;
  }

  Future<void> _refreshPermissions() async {
    final snapshot = await DoppelPlatform.getSnapshot();
    if (!mounted) {
      return;
    }
    widget.onSnapshotChanged(snapshot);
    setState(() {
      _permissions = snapshot.permissions;
    });
  }

  Future<void> _requestPermissions() async {
    await DoppelPlatform.requestRequiredPermissions();
    await _refreshPermissions();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('系统设置'),
        surfaceTintColor: Colors.transparent,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          SectionCard(
            title: '权限状态',
            badge: StatusBadge(
              text: _permissions.hasRequiredPermissions ? '完整' : '待授权',
              tone: _permissions.hasRequiredPermissions
                  ? BadgeTone.success
                  : BadgeTone.warning,
            ),
            child: Column(
              children: [
                PermissionRow(label: '接收短信', granted: _permissions.receiveSms),
                const Divider(height: 1),
                PermissionRow(label: '发送短信', granted: _permissions.sendSms),
                const Divider(height: 1),
                PermissionRow(label: '拨打电话', granted: _permissions.callPhone),
                const Divider(height: 1),
                PermissionRow(
                  label: '读取电话状态',
                  granted: _permissions.readPhoneState,
                ),
                const Divider(height: 1),
                PermissionRow(
                  label: '读取本机号码',
                  granted: _permissions.readPhoneNumbers,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.refresh_outlined),
                        label: const Text('刷新'),
                        onPressed: _refreshPermissions,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.security_outlined),
                        label: const Text('申请授权'),
                        onPressed: _requestPermissions,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '运行配置',
            child: Column(
              children: [
                ToggleRow(
                  icon: Icons.phone_in_talk_outlined,
                  title: '自动接听',
                  subtitle: '默认关闭，只记录来电',
                  value: _autoAnswer,
                  onChanged: (value) => setState(() => _autoAnswer = value),
                ),
                const Divider(height: 1),
                const SummaryRow(
                  icon: Icons.history_outlined,
                  title: '日志保留天数',
                  subtitle: '30 天',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
