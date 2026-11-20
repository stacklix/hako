import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../platform/nami_platform.dart';
import '../widgets/common_widgets.dart';
import '../widgets/dialogs.dart';
import '../widgets/forwarding_widgets.dart';

class ForwardingPage extends StatefulWidget {
  const ForwardingPage({
    super.key,
    required this.simCards,
    required this.initialConfig,
  });

  final List<SimCardInfo> simCards;
  final ForwardingConfig initialConfig;

  @override
  State<ForwardingPage> createState() => _ForwardingPageState();
}

class _ForwardingPageState extends State<ForwardingPage> {
  final List<ForwardTarget> _phoneTargets = [];
  final List<ForwardTarget> _emailTargets = [];
  final List<ForwardTarget> _httpTargets = [];
  String? _selectedSmsSim;
  SmtpSettings? _smtpSettings;
  bool _loadedInitialConfig = false;

  List<String> get _simLabels {
    if (widget.simCards.isEmpty) {
      return const [];
    }
    return widget.simCards.map((sim) => sim.label).toList();
  }

  String? get _selectedSmsSimLabel {
    final labels = _simLabels;
    if (labels.isEmpty) {
      return null;
    }
    final selected = _selectedSmsSim;
    if (selected != null && labels.contains(selected)) {
      return selected;
    }
    return labels.first;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadInitialConfig();
  }

  @override
  void didUpdateWidget(covariant ForwardingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialConfig != widget.initialConfig) {
      _loadedInitialConfig = false;
      _loadInitialConfig();
    }
  }

  void _loadInitialConfig() {
    if (_loadedInitialConfig || !widget.initialConfig.hasData) {
      return;
    }
    _phoneTargets
      ..clear()
      ..addAll(widget.initialConfig.smsTargets);
    _emailTargets
      ..clear()
      ..addAll(widget.initialConfig.emailTargets);
    _httpTargets
      ..clear()
      ..addAll(widget.initialConfig.httpTargets);
    _selectedSmsSim = widget.initialConfig.selectedSmsSim;
    _smtpSettings = widget.initialConfig.smtp;
    _loadedInitialConfig = true;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          Material(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: const TabBar(
              tabs: [
                Tab(text: '转发到手机号'),
                Tab(text: '转发到邮箱'),
                Tab(text: '推送到服务器'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                ForwardTargetTab(
                  title: '转发到手机号',
                  badge: const StatusBadge(text: '非命令短信'),
                  targets: _phoneTargets,
                  emptyText: '还没有配置手机号',
                  addLabel: '添加手机号',
                  onDelete: _deleteTarget,
                  onAdd: () => _addTarget(
                    title: '添加转发手机号',
                    label: '手机号',
                    hint: '+86 13800138000',
                    targets: _phoneTargets,
                    onPersist: _persistPhoneForwardingConfig,
                  ),
                  header: SimSelectorCard(
                    selectedSim: _selectedSmsSimLabel,
                    simLabels: _simLabels,
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _selectedSmsSim = value;
                      });
                      _persistPhoneForwardingConfig();
                    },
                  ),
                ),
                ForwardTargetTab(
                  title: '转发到邮箱',
                  targets: _emailTargets,
                  emptyText: '还没有配置邮箱收件人',
                  addLabel: '添加邮箱',
                  onDelete: _deleteTarget,
                  onAdd: () => _addTarget(
                    title: '添加邮箱收件人',
                    label: '邮箱',
                    hint: 'notify@example.com',
                    targets: _emailTargets,
                    onPersist: _persistEmailForwardingConfig,
                  ),
                  header: SmtpSettingsCard(
                    settings: _smtpSettings,
                    onConfigure: _configureSmtpSettings,
                  ),
                ),
                ForwardTargetTab(
                  title: '推送到服务器',
                  targets: _httpTargets,
                  emptyText: '还没有配置 HTTP 推送地址',
                  addLabel: '添加 HTTP',
                  onDelete: _deleteTarget,
                  onAdd: () => _addTarget(
                    title: '添加 HTTP 推送地址',
                    label: 'HTTP URL',
                    hint: 'https://example.com/sms',
                    targets: _httpTargets,
                    onPersist: _persistHttpForwardingConfig,
                  ),
                  footer: const PayloadPreview(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addTarget({
    required String title,
    required String label,
    required String hint,
    required List<ForwardTarget> targets,
    required Future<void> Function() onPersist,
  }) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => TextValueDialog(title: title, label: label, hint: hint),
    );

    if (value == null ||
        value.isEmpty ||
        targets.any((target) => target.value == value)) {
      return;
    }

    setState(() {
      targets.add(ForwardTarget(value: value));
    });
    onPersist();
  }

  void _deleteTarget(ForwardTarget target) {
    final isPhoneTarget = _phoneTargets.contains(target);
    final isEmailTarget = _emailTargets.contains(target);
    final isHttpTarget = _httpTargets.contains(target);
    setState(() {
      _phoneTargets.remove(target);
      _emailTargets.remove(target);
      _httpTargets.remove(target);
    });
    if (isPhoneTarget) {
      _persistPhoneForwardingConfig();
    } else if (isEmailTarget) {
      _persistEmailForwardingConfig();
    } else if (isHttpTarget) {
      _persistHttpForwardingConfig();
    }
  }

  Future<void> _configureSmtpSettings() async {
    final settings = await showDialog<SmtpSettings>(
      context: context,
      builder: (_) => SmtpSettingsDialog(initialValue: _smtpSettings),
    );

    if (settings == null) {
      return;
    }

    setState(() {
      _smtpSettings = settings;
    });
    _persistEmailForwardingConfig();
  }

  Future<void> _persistPhoneForwardingConfig() {
    return NamiPlatform.saveConfig({
      'forwarding': {
        'smsTargets': _phoneTargets.map((target) => target.toMap()).toList(),
        if (_selectedSmsSimLabel != null)
          'selectedSmsSim': _selectedSmsSimLabel,
      },
    });
  }

  Future<void> _persistEmailForwardingConfig() {
    return NamiPlatform.saveConfig({
      'forwarding': {
        'emailTargets': _emailTargets.map((target) => target.toMap()).toList(),
        if (_smtpSettings != null) 'smtp': _smtpSettings?.toMap(),
      },
    });
  }

  Future<void> _persistHttpForwardingConfig() {
    return NamiPlatform.saveConfig({
      'forwarding': {
        'httpTargets': _httpTargets.map((target) => target.toMap()).toList(),
      },
    });
  }
}
