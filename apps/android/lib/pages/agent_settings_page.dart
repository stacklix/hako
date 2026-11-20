import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/agent_models.dart';
import '../platform/nami_platform.dart';
import '../widgets/common_widgets.dart';

class AgentSettingsPage extends StatefulWidget {
  const AgentSettingsPage({super.key});

  @override
  State<AgentSettingsPage> createState() => _AgentSettingsPageState();
}

class _AgentSettingsPageState extends State<AgentSettingsPage>
    with WidgetsBindingObserver {
  final _form = GlobalKey<FormState>();
  final _server = TextEditingController();
  final _username = TextEditingController();
  AgentSettings _settings = const AgentSettings();
  bool _enabled = false;
  bool _allowSms = false;
  bool _allowCalls = false;
  bool _loading = true;
  bool _busy = false;
  bool _refreshing = false;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh(initial: true);
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _server.dispose();
    _username.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _showError(Object error) {
    final message = error is PlatformException
        ? error.message ?? '操作失败，请重试'
        : '无法读取手机端 Agent 设置，请重试';
    if (mounted) setState(() => _error = message);
  }

  Future<void> _refresh({bool initial = false}) async {
    if (_busy || _refreshing) return;
    _refreshing = true;
    try {
      final value = await NamiPlatform.getAgentSettings();
      if (!mounted) return;
      setState(() {
        _settings = value;
        if (initial || _loading) {
          _server.text = value.server;
          _username.text = value.username;
          _enabled = value.enabled;
          _allowSms = value.allowSms;
          _allowCalls = value.allowCalls;
        }
        _loading = false;
      });
    } catch (error) {
      _showError(error);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _run(Future<AgentSettings> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final value = await action();
      if (!mounted) return;
      setState(() => _settings = value);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_enabled && _settings.publicKey.isEmpty) {
      setState(() => _error = '请先生成设备密钥，并在 Sora 中登记公钥');
      return;
    }
    await _run(
      () => NamiPlatform.saveAgentSettings({
        'enabled': _enabled,
        'server': _server.text.trim(),
        'username': _username.text.trim(),
        'allowSms': _allowSms,
        'allowCalls': _allowCalls,
      }),
    );
    if (mounted && _error == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Agent 配置已保存')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nami Agent')),
      body: _loading
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!),
                        TextButton(
                          onPressed: () => _refresh(initial: true),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
            )
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  SectionCard(
                    title: '连接状态',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _settings.state == 'connected'
                                  ? Icons.cloud_done_outlined
                                  : Icons.cloud_off_outlined,
                              color: _settings.state == 'connected'
                                  ? Colors.teal
                                  : Colors.grey,
                            ),
                            const SizedBox(width: 10),
                            Expanded(child: Text(_settings.message)),
                          ],
                        ),
                        if (_settings.agentId.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          SelectableText('设备 ID：${_settings.agentId}'),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SectionCard(
                    title: '服务器与账号',
                    child: Column(
                      children: [
                        TextFormField(
                          controller: _server,
                          enabled: !_busy,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Sora 服务器地址',
                            floatingLabelBehavior: FloatingLabelBehavior.always,
                            hintText: 'https://hako.example.com',
                          ),
                          validator: (value) {
                            if (!_enabled && (value ?? '').trim().isEmpty) {
                              return null;
                            }
                            final uri = Uri.tryParse((value ?? '').trim());
                            if (uri == null ||
                                uri.scheme != 'https' ||
                                uri.host.isEmpty ||
                                uri.userInfo.isNotEmpty ||
                                (uri.path.isNotEmpty && uri.path != '/') ||
                                uri.hasQuery ||
                                uri.hasFragment) {
                              return '请输入 HTTPS 服务器地址，不包含路径';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _username,
                          enabled: !_busy,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Sora 账号',
                            floatingLabelBehavior: FloatingLabelBehavior.always,
                          ),
                          validator: (value) =>
                              _enabled && (value ?? '').trim().isEmpty
                              ? '请输入账号'
                              : null,
                        ),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('启用 Agent'),
                          subtitle: const Text('保持与 Sora 连接，并显示后台运行通知'),
                          value: _enabled,
                          onChanged: _busy
                              ? null
                              : (value) => setState(() => _enabled = value),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SectionCard(
                    title: '设备密钥',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('生成后，将公钥添加到 Sora 的设备管理。私钥保存在此手机的系统密钥库中。'),
                        const SizedBox(height: 12),
                        if (_settings.publicKey.isEmpty)
                          FilledButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _run(NamiPlatform.generateAgentKey),
                            icon: const Icon(Icons.key_outlined),
                            label: const Text('生成设备密钥'),
                          )
                        else ...[
                          const Text('公钥指纹'),
                          SelectableText(_settings.keyId),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: _settings.publicKey),
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('公钥已复制')),
                                );
                              }
                            },
                            icon: const Icon(Icons.copy_outlined),
                            label: const Text('复制设备公钥'),
                          ),
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: const Text('查看公钥'),
                            children: [
                              SelectableText(
                                _settings.publicKey,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SectionCard(
                    title: '远程操作权限',
                    child: Column(
                      children: [
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('允许远程发送短信'),
                          subtitle: const Text('还需要手机系统的发送短信权限'),
                          value: _allowSms,
                          onChanged: _busy
                              ? null
                              : (value) => setState(() => _allowSms = value),
                        ),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('允许远程拨号'),
                          subtitle: const Text('拨号请求的提交结果不代表电话已接通'),
                          value: _allowCalls,
                          onChanged: _busy
                              ? null
                              : (value) => setState(() => _allowCalls = value),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SectionCard(
                    title: '后台运行',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _settings.batteryExempt
                              ? '已允许忽略电池优化'
                              : '请在系统设置中允许 Nami 不受电池优化限制',
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '部分手机还需允许自启动和后台运行。网络切换后会自动重连；短信和通话历史按需分页查询。',
                        ),
                        TextButton(
                          onPressed: () async {
                            try {
                              await NamiPlatform.openBatterySettings();
                            } catch (error) {
                              _showError(error);
                            }
                          },
                          child: const Text('打开电池优化设置'),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _save,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: const Text('保存并应用'),
                  ),
                ],
              ),
            ),
    );
  }
}
