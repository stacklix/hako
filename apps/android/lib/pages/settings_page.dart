import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_models.dart';
import '../models/system_settings.dart';
import '../models/wifi_permissions.dart';
import '../platform/nami_platform.dart';
import '../widgets/common_widgets.dart';
import 'agent_settings_page.dart';

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

class _SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {
  bool _autoAnswer = false;
  late PlatformPermissions _permissions;
  SystemSettingsStatus? _systemSettings;
  String? _settingsError;
  bool _refreshingSettings = false;
  bool _openingSettings = false;
  WifiPermissions? _wifiPermissions;
  bool _requestingWifi = false;
  String? _wifiError;

  @override
  void initState() {
    super.initState();
    _permissions = widget.permissions;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshSystemSettings());
    unawaited(_refreshWifiPermissions());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshSystemSettings());
      unawaited(_refreshPermissions());
      unawaited(_refreshWifiPermissions());
    }
  }

  Future<void> _refreshSystemSettings() async {
    if (_refreshingSettings) return;
    _refreshingSettings = true;
    try {
      final settings = await NamiPlatform.getSystemSettings();
      if (!mounted) return;
      setState(() {
        _systemSettings = settings;
        _settingsError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _settingsError = error is PlatformException
            ? error.message ?? '无法读取系统设置状态，请重试'
            : '无法读取系统设置状态，请重试',
      );
    } finally {
      _refreshingSettings = false;
    }
  }

  Future<void> _openSystemSettings(SystemSettingsTarget target) async {
    if (_openingSettings) return;
    setState(() => _openingSettings = true);
    try {
      await NamiPlatform.openSystemSettings(target);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is PlatformException
                ? error.message ?? '无法打开设置，请从手机系统设置进入'
                : '无法打开设置，请从手机系统设置进入',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _openingSettings = false);
    }
  }

  Widget _settingsEntry({
    required IconData icon,
    required String title,
    required String subtitle,
    required SystemSettingsTarget target,
    bool enabled = true,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      enabled: enabled && !_openingSettings,
      onTap: enabled ? () => _openSystemSettings(target) : null,
    );
  }

  Widget _systemSettingsCard() {
    final settings = _systemSettings;
    return SectionCard(
      title: '后台运行与系统设置',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('允许自启动和后台运行，减少短信转发与设备连接被系统中断。'),
          const SizedBox(height: 8),
          _settingsEntry(
            icon: Icons.power_settings_new_outlined,
            title: '开机自启动',
            subtitle: settings == null
                ? '正在读取系统入口…'
                : settings.autoStartAvailable
                ? '打开系统自启动管理，允许 Nami 自启动'
                : '此系统未提供快捷入口，请在应用详情中查找',
            target: SystemSettingsTarget.autoStart,
            enabled: settings?.autoStartAvailable == true,
          ),
          const Divider(height: 1),
          _settingsEntry(
            icon: Icons.battery_saver_outlined,
            title: '后台省电策略',
            subtitle: settings == null
                ? '正在读取系统入口…'
                : settings.backgroundAvailable
                ? '打开 Nami 省电设置，选择「无限制」'
                : '此系统未提供快捷入口，请在应用详情中查找',
            target: SystemSettingsTarget.background,
            enabled: settings?.backgroundAvailable == true,
          ),
          const Divider(height: 1),
          _settingsEntry(
            icon: Icons.battery_charging_full_outlined,
            title: '电池优化',
            subtitle: settings == null
                ? '打开系统电池优化设置'
                : settings.batteryExempt
                ? '已忽略电池优化'
                : '尚未忽略电池优化，建议允许后台运行',
            target: SystemSettingsTarget.battery,
          ),
          const Divider(height: 1),
          _settingsEntry(
            icon: Icons.notifications_outlined,
            title: '通知设置',
            subtitle: settings == null
                ? '管理 Nami 通知权限'
                : settings.notificationsEnabled
                ? '通知已允许'
                : '通知未允许，点击前往设置',
            target: SystemSettingsTarget.notifications,
          ),
          const Divider(height: 1),
          _settingsEntry(
            icon: Icons.app_settings_alt_outlined,
            title: '应用权限与详情',
            subtitle: '管理短信、电话、后台运行等系统权限',
            target: SystemSettingsTarget.application,
          ),
          const SizedBox(height: 8),
          const Text(
            '自启动与省电策略由手机系统管理，请在打开的页面中确认；返回后会刷新电池优化、通知和权限状态。',
            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          if (_settingsError != null) ...[
            const SizedBox(height: 8),
            Text(
              _settingsError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            TextButton(
              onPressed: _refreshSystemSettings,
              child: const Text('重试'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _refreshPermissions() async {
    final snapshot = await NamiPlatform.getSnapshot();
    if (!mounted) {
      return;
    }
    widget.onSnapshotChanged(snapshot);
    setState(() {
      _permissions = snapshot.permissions;
    });
  }

  Future<void> _requestPermissions() async {
    await NamiPlatform.requestRequiredPermissions();
    await _refreshPermissions();
  }

  Future<void> _refreshWifiPermissions() async {
    try {
      final permissions = await NamiPlatform.getWifiPermissions();
      if (mounted) {
        setState(() {
          _wifiPermissions = permissions;
          _wifiError = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _wifiError = '暂时无法读取 Wi-Fi 名称权限');
    }
  }

  Future<void> _requestWifiPermissions({bool locationSettings = false}) async {
    if (_requestingWifi) return;
    if (!locationSettings &&
        _wifiPermissions?.preciseLocationGranted == true &&
        _wifiPermissions?.backgroundLocationGranted != true) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('后台读取 Wi-Fi 名称'),
          content: const Text(
            'Android 将 Wi-Fi 名称视为与位置有关的信息。如需手机在后台时仍上报网络名称，请在 Nami 的位置权限中选择「始终允许」并开启精确位置。Nami 不采集 GPS 轨迹；不授权也可继续使用其他功能。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('暂不授权'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('前往设置'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }
    setState(() => _requestingWifi = true);
    try {
      if (locationSettings) {
        await NamiPlatform.openWifiLocationSettings();
      } else {
        await NamiPlatform.requestWifiPermissions();
      }
      await _refreshWifiPermissions();
    } catch (error) {
      if (mounted) {
        setState(
          () => _wifiError = error is PlatformException
              ? error.message ?? '无法打开 Wi-Fi 权限设置'
              : '无法打开 Wi-Fi 权限设置',
        );
      }
    } finally {
      if (mounted) setState(() => _requestingWifi = false);
    }
  }

  Widget _wifiPermissionsCard() {
    final permissions = _wifiPermissions;
    return SectionCard(
      title: 'Wi-Fi 信息',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('用于在 Hako 展示当前连接的 Wi-Fi 名称、信号和连接速率，不扫描周边网络，不采集 GPS 轨迹。'),
          const SizedBox(height: 12),
          PermissionRow(
            label: '精确位置授权（读取网络名称）',
            granted: permissions?.preciseLocationGranted == true,
          ),
          PermissionRow(
            label: '后台读取授权',
            granted: permissions?.backgroundLocationGranted == true,
          ),
          PermissionRow(
            label: '系统定位服务',
            granted: permissions?.locationEnabled == true,
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _requestingWifi ? null : () => _requestWifiPermissions(),
            child: Text(
              permissions?.preciseLocationGranted == true
                  ? 'Wi-Fi 名称权限设置'
                  : '授权读取 Wi-Fi 名称',
            ),
          ),
          TextButton(
            onPressed: _requestingWifi
                ? null
                : () => _requestWifiPermissions(locationSettings: true),
            child: const Text('定位服务设置'),
          ),
          TextButton(
            onPressed: () =>
                _openSystemSettings(SystemSettingsTarget.application),
            child: const Text('应用权限设置'),
          ),
          if (_wifiError != null)
            Text(
              _wifiError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
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
            title: 'Nami Agent',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.devices_outlined),
              title: const Text('连接到 Hako'),
              subtitle: const Text('设备登记、后台连接与远程操作权限'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AgentSettingsPage(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _systemSettingsCard(),
          const SizedBox(height: 12),
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
                PermissionRow(label: '读取短信历史', granted: _permissions.readSms),
                const Divider(height: 1),
                PermissionRow(
                  label: '读取通话记录',
                  granted: _permissions.readCallLog,
                ),
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
          const SizedBox(height: 12),
          _wifiPermissionsCard(),
        ],
      ),
    );
  }
}
