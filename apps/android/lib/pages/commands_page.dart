import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../platform/nami_platform.dart';
import '../widgets/common_widgets.dart';
import '../widgets/dialogs.dart';

class CommandsPage extends StatefulWidget {
  const CommandsPage({
    super.key,
    required this.initialConfig,
    required this.remoteConfig,
    required this.remoteStatus,
  });

  final CommandsConfig initialConfig;
  final RemoteControlConfig remoteConfig;
  final RemoteControlStatus remoteStatus;

  @override
  State<CommandsPage> createState() => _CommandsPageState();
}

class _CommandsPageState extends State<CommandsPage> {
  final List<TrustedNumber> _trustedNumbers = [];
  bool _callEnabled = true;
  bool _smsEnabled = true;
  late bool _remoteEnabled;
  late TextEditingController _remotePortController;
  late TextEditingController _remotePasswordController;
  late TextEditingController _remoteTokenController;
  bool _remotePasswordVisible = false;
  bool _remoteConfigDirty = false;
  bool _loadedInitialConfig = false;

  @override
  void initState() {
    super.initState();
    _remoteEnabled = widget.remoteConfig.enabled;
    _remotePortController = TextEditingController(
      text: widget.remoteConfig.port,
    );
    _remotePasswordController = TextEditingController(
      text: widget.remoteConfig.password,
    );
    _remoteTokenController = TextEditingController(
      text: widget.remoteConfig.token,
    );
  }

  @override
  void dispose() {
    _remotePortController.dispose();
    _remotePasswordController.dispose();
    _remoteTokenController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadInitialConfig();
  }

  @override
  void didUpdateWidget(covariant CommandsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialConfig != widget.initialConfig) {
      _loadedInitialConfig = false;
      _loadInitialConfig();
    }
    if (!_remoteConfigDirty && oldWidget.remoteConfig != widget.remoteConfig) {
      _remoteEnabled = widget.remoteConfig.enabled;
      _remotePortController.text = widget.remoteConfig.port;
      _remotePasswordController.text = widget.remoteConfig.password;
      _remoteTokenController.text = widget.remoteConfig.token;
    }
  }

  void _loadInitialConfig() {
    if (_loadedInitialConfig || !widget.initialConfig.hasData) {
      return;
    }
    _trustedNumbers
      ..clear()
      ..addAll(widget.initialConfig.trustedNumbers);
    _callEnabled = widget.initialConfig.callEnabled;
    _smsEnabled = widget.initialConfig.smsEnabled;
    _loadedInitialConfig = true;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        SectionCard(
          title: '短信指令',
          badge: StatusBadge(text: '${_trustedNumbers.length} 个'),
          child: Column(
            children: [
              ToggleRow(
                icon: Icons.call_outlined,
                title: '远程打电话',
                subtitle: 'DOPPEL CALL 13800138000',
                value: _callEnabled,
                onChanged: (value) {
                  setState(() => _callEnabled = value);
                  _persistCommandConfig();
                },
              ),
              const Divider(height: 1),
              ToggleRow(
                icon: Icons.sms_outlined,
                title: '远程发短信',
                subtitle: 'DOPPEL SMS 13800138000 你好',
                value: _smsEnabled,
                onChanged: (value) {
                  setState(() => _smsEnabled = value);
                  _persistCommandConfig();
                },
              ),
              const Divider(height: 1),
              const Padding(
                padding: EdgeInsets.only(top: 12, bottom: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '可信号码',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              for (final number in _trustedNumbers) ...[
                EditableTrustedNumberRow(
                  trustedNumber: number,
                  onEdit: () =>
                      _showTrustedNumberDialog(context, initialValue: number),
                ),
                if (number != _trustedNumbers.last) const Divider(height: 1),
              ],
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('添加号码'),
                  onPressed: () => _showAddTrustedNumberDialog(context),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'HTTP 指令',
          badge: StatusBadge(
            text: _remoteEnabled ? '已开启' : '未开启',
            tone: _remoteEnabled ? BadgeTone.success : BadgeTone.warning,
          ),
          child: Column(
            children: [
              const _InlineSectionLabel('运行状态'),
              const SizedBox(height: 6),
              SummaryRow(
                icon: Icons.language_outlined,
                title: '远程 HTTP 控制',
                subtitle: '开启或关闭当前 HTTP 服务部署',
                trailing: Tooltip(
                  message: _remoteEnabled ? '关闭远程 HTTP 控制' : '启用远程 HTTP 控制',
                  child: Switch(
                    value: _remoteEnabled,
                    onChanged: _persistRemoteControlEnabled,
                  ),
                ),
              ),
              const Divider(height: 1),
              SummaryRow(
                icon: Icons.wifi_tethering_outlined,
                title: '当前 IP',
                subtitle: widget.remoteStatus.ipLabel,
              ),
              const Divider(height: 1),
              SummaryRow(
                icon: Icons.power_settings_new_outlined,
                title: '服务状态',
                subtitle: widget.remoteStatus.runningLabel,
              ),
              const Divider(height: 1),
              const SizedBox(height: 10),
              const _InlineSectionLabel('服务配置'),
              const SizedBox(height: 6),
              TextField(
                controller: _remotePortController,
                decoration: const InputDecoration(
                  labelText: '监听端口',
                  prefixIcon: Icon(Icons.settings_ethernet_outlined),
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => _updateRemoteConfigDirty(),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _remotePasswordController,
                decoration: InputDecoration(
                  labelText: '管理密码',
                  prefixIcon: const Icon(Icons.password_outlined),
                  helperText: '必须设置密码后才允许远程登录',
                  suffixIcon: IconButton(
                    tooltip: _remotePasswordVisible ? '隐藏管理密码' : '显示管理密码',
                    icon: Icon(
                      _remotePasswordVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    onPressed: _toggleRemotePasswordVisibility,
                  ),
                ),
                obscureText: !_remotePasswordVisible,
                onChanged: (_) => _updateRemoteConfigDirty(),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _remoteTokenController,
                decoration: const InputDecoration(
                  labelText: '接口 Token',
                  prefixIcon: Icon(Icons.key_outlined),
                  helperText: '外部 API 调用使用 Authorization: Bearer <token>',
                ),
                obscureText: true,
                onChanged: (_) => _updateRemoteConfigDirty(),
              ),
              if (_remoteConfigDirty) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存远程控制'),
                    onPressed: _persistRemoteControlConfig,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showAddTrustedNumberDialog(BuildContext context) async {
    await _showTrustedNumberDialog(context);
  }

  Future<void> _showTrustedNumberDialog(
    BuildContext context, {
    TrustedNumber? initialValue,
  }) async {
    final result = await showDialog<TrustedNumberDialogResult>(
      context: context,
      builder: (_) => TrustedNumberDialog(initialValue: initialValue),
    );

    if (result == null) {
      return;
    }

    if (result.delete) {
      if (initialValue == null) {
        return;
      }
      setState(() {
        _trustedNumbers.remove(initialValue);
      });
      _persistCommandConfig();
      return;
    }

    final value = result.value;
    if (value == null ||
        value.number.isEmpty ||
        _trustedNumbers.any(
          (item) => item != initialValue && item.number == value.number,
        )) {
      return;
    }

    setState(() {
      if (initialValue == null) {
        _trustedNumbers.add(value);
      } else {
        final index = _trustedNumbers.indexOf(initialValue);
        _trustedNumbers[index] = value;
      }
    });
    _persistCommandConfig();
  }

  Future<void> _persistCommandConfig() {
    return NamiPlatform.saveConfig({
      'commands': {
        'callEnabled': _callEnabled,
        'smsEnabled': _smsEnabled,
        'trustedNumbers': _trustedNumbers
            .map((number) => number.toMap())
            .toList(),
      },
    });
  }

  void _updateRemoteConfigDirty() {
    final currentPort = _remotePortController.text.trim().isEmpty
        ? '18080'
        : _remotePortController.text.trim();
    final isDirty =
        currentPort != widget.remoteConfig.port ||
        _remotePasswordController.text != widget.remoteConfig.password ||
        _remoteTokenController.text != widget.remoteConfig.token;
    if (_remoteConfigDirty == isDirty) {
      return;
    }
    setState(() => _remoteConfigDirty = isDirty);
  }

  void _toggleRemotePasswordVisibility() {
    setState(() {
      _remotePasswordVisible = !_remotePasswordVisible;
    });
  }

  Future<void> _persistRemoteControlConfig() async {
    final port = _remotePortController.text.trim().isEmpty
        ? '18080'
        : _remotePortController.text.trim();
    await NamiPlatform.saveConfig({
      'remoteControl': {
        'port': port,
        'password': _remotePasswordController.text,
        'token': _remoteTokenController.text,
      },
    });
    if (!mounted) {
      return;
    }
    setState(() => _remoteConfigDirty = false);
  }

  Future<void> _persistRemoteControlEnabled(bool value) async {
    setState(() => _remoteEnabled = value);
    await NamiPlatform.saveConfig({
      'remoteControl': {'enabled': value},
    });
  }
}

class _InlineSectionLabel extends StatelessWidget {
  const _InlineSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF0F766E),
          fontSize: 14,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class EditableTrustedNumberRow extends StatelessWidget {
  const EditableTrustedNumberRow({
    super.key,
    required this.trustedNumber,
    required this.onEdit,
  });

  final TrustedNumber trustedNumber;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return SummaryRow(
      icon: Icons.person_outline,
      title: trustedNumber.number,
      subtitle: trustedNumber.subtitleLabel,
      trailing: IconButton(
        tooltip: '编辑 ${trustedNumber.number}',
        icon: const Icon(Icons.edit_outlined),
        onPressed: onEdit,
      ),
    );
  }
}
