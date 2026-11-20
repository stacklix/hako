import 'package:flutter/material.dart';

class AppMetric {
  const AppMetric({
    required this.title,
    required this.todayLabel,
    required this.totalLabel,
    required this.todayValue,
    required this.totalValue,
    required this.helpText,
  });

  final String title;
  final String todayLabel;
  final String totalLabel;
  final String todayValue;
  final String totalValue;
  final String helpText;
}

class ForwardTarget {
  ForwardTarget({required this.value});

  factory ForwardTarget.fromMap(Map<String, Object?> map) {
    return ForwardTarget(value: _asString(map['value']));
  }

  final String value;

  Map<String, Object?> toMap() {
    return {'value': value};
  }
}

class SmtpSettings {
  const SmtpSettings({
    required this.host,
    required this.port,
    required this.fromEmail,
    required this.username,
    required this.password,
  });

  factory SmtpSettings.fromMap(Map<String, Object?> map) {
    return SmtpSettings(
      host: _asString(map['host']),
      port: _asString(map['port']),
      fromEmail: _asString(map['fromEmail']),
      username: _asString(map['username']),
      password: _asString(map['password']),
    );
  }

  final String host;
  final String port;
  final String fromEmail;
  final String username;
  final String password;

  String get effectivePort => port.isEmpty ? '465' : port;

  String get signature {
    return '$host:$effectivePort:$fromEmail:$username:${password.isEmpty ? 0 : 1}';
  }

  Map<String, Object?> toMap() {
    return {
      'host': host,
      'port': port,
      'fromEmail': fromEmail,
      'username': username,
      'password': password,
    };
  }
}

class TrustedNumber {
  const TrustedNumber({required this.number});

  factory TrustedNumber.fromMap(Map<String, Object?> map) {
    return TrustedNumber(number: _asString(map['number']));
  }

  final String number;

  Map<String, Object?> toMap() {
    return {'number': number};
  }

  String get subtitleLabel => '可信号码';
}

class TrustedNumberDialogResult {
  const TrustedNumberDialogResult.save(this.value) : delete = false;

  const TrustedNumberDialogResult.delete() : value = null, delete = true;

  final TrustedNumber? value;
  final bool delete;
}

class PlatformSnapshot {
  const PlatformSnapshot({
    this.permissions = const PlatformPermissions(),
    this.config = const AppConfig(),
    this.remoteControlStatus = const RemoteControlStatus(),
    this.simCards = const [],
    this.events = const [],
  });

  factory PlatformSnapshot.fromMap(Map<String, Object?> map) {
    return PlatformSnapshot(
      permissions: PlatformPermissions.fromMap(_asMap(map['permissions'])),
      config: AppConfig.fromMap(_asMap(map['config'])),
      remoteControlStatus: RemoteControlStatus.fromMap(
        _asMap(map['remoteControlStatus']),
      ),
      simCards: _asList(
        map['simCards'],
      ).map(_asMap).map(SimCardInfo.fromMap).toList(),
      events: _sortedEvents(
        _recentImportedSmsEventsOnly(
          _asList(map['events']).map(_asMap).map(LogEvent.fromMap).toList(),
        ),
      ),
    );
  }

  final PlatformPermissions permissions;
  final AppConfig config;
  final RemoteControlStatus remoteControlStatus;
  final List<SimCardInfo> simCards;
  final List<LogEvent> events;

  bool get hasRequiredPermissions => permissions.hasRequiredPermissions;
}

class RemoteControlStatus {
  const RemoteControlStatus({
    this.ipAddresses = const [],
    this.isRunning = false,
    this.port,
  });

  factory RemoteControlStatus.fromMap(Map<String, Object?> map) {
    return RemoteControlStatus(
      ipAddresses: _asList(map['ipAddresses']).map(_asString).toList(),
      isRunning: map['isRunning'] == true,
      port: _asNullableInt(map['port']),
    );
  }

  final List<String> ipAddresses;
  final bool isRunning;
  final int? port;

  String get ipLabel {
    return ipAddresses.isEmpty ? '未检测到局域网 IP' : ipAddresses.join(', ');
  }

  String get runningLabel {
    if (!isRunning) {
      return '未运行';
    }
    return port == null ? '运行中' : '运行中，端口 $port';
  }
}

List<LogEvent> _sortedEvents(List<LogEvent> events) {
  return [...events]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
}

List<LogEvent> _recentImportedSmsEventsOnly(List<LogEvent> events) {
  final cutoff = DateTime.now().subtract(const Duration(days: 30));
  return events.where((event) {
    if (event.source != 'system_sms') {
      return true;
    }
    return event.timestamp.isAfter(cutoff);
  }).toList();
}

class PlatformPermissions {
  const PlatformPermissions({
    this.readSms = false,
    this.readCallLog = false,
    this.receiveSms = false,
    this.sendSms = false,
    this.callPhone = false,
    this.readPhoneState = false,
    this.readPhoneNumbers = false,
  });

  factory PlatformPermissions.fromMap(Map<String, Object?> map) {
    return PlatformPermissions(
      readSms: map['readSms'] == true,
      readCallLog: map['readCallLog'] == true,
      receiveSms: map['receiveSms'] == true || map['sms'] == true,
      sendSms: map['sendSms'] == true || map['sms'] == true,
      callPhone: map['callPhone'] == true || map['phone'] == true,
      readPhoneState: map['readPhoneState'] == true || map['phone'] == true,
      readPhoneNumbers:
          map['readPhoneNumbers'] == true || map['phoneNumbers'] == true,
    );
  }

  final bool readSms;
  final bool readCallLog;
  final bool receiveSms;
  final bool sendSms;
  final bool callPhone;
  final bool readPhoneState;
  final bool readPhoneNumbers;

  bool get hasRequiredPermissions {
    return receiveSms && sendSms && callPhone && readPhoneState;
  }
}

class AppConfig {
  const AppConfig({
    this.forwarding = const ForwardingConfig(),
    this.commands = const CommandsConfig(),
    this.remoteControl = const RemoteControlConfig(),
  });

  factory AppConfig.fromMap(Map<String, Object?> map) {
    return AppConfig(
      forwarding: ForwardingConfig.fromMap(_asMap(map['forwarding'])),
      commands: CommandsConfig.fromMap(_asMap(map['commands'])),
      remoteControl: RemoteControlConfig.fromMap(_asMap(map['remoteControl'])),
    );
  }

  final ForwardingConfig forwarding;
  final CommandsConfig commands;
  final RemoteControlConfig remoteControl;
}

class RemoteControlConfig {
  const RemoteControlConfig({
    this.enabled = false,
    this.port = '18080',
    this.password = '',
    this.token = '',
  });

  factory RemoteControlConfig.fromMap(Map<String, Object?> map) {
    return RemoteControlConfig(
      enabled: map['enabled'] == true,
      port: _asString(map['port'], fallback: '18080'),
      password: _asString(map['password']),
      token: _asString(map['token']),
    );
  }

  final bool enabled;
  final String port;
  final String password;
  final String token;

  bool get canRun => enabled && password.isNotEmpty;

  Map<String, Object?> toMap() {
    return {
      'enabled': enabled,
      'port': port,
      'password': password,
      'token': token,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is RemoteControlConfig &&
        other.enabled == enabled &&
        other.port == port &&
        other.password == password &&
        other.token == token;
  }

  @override
  int get hashCode => Object.hash(enabled, port, password, token);
}

class ForwardingConfig {
  const ForwardingConfig({
    this.smsTargets = const [],
    this.emailTargets = const [],
    this.httpTargets = const [],
    this.selectedSmsSim,
    this.smtp,
    this.hasData = false,
  });

  factory ForwardingConfig.fromMap(Map<String, Object?> map) {
    if (map.isEmpty) {
      return const ForwardingConfig();
    }
    return ForwardingConfig(
      smsTargets: _asList(
        map['smsTargets'],
      ).map(_asMap).map(ForwardTarget.fromMap).toList(),
      emailTargets: _asList(
        map['emailTargets'],
      ).map(_asMap).map(ForwardTarget.fromMap).toList(),
      httpTargets: _asList(
        map['httpTargets'],
      ).map(_asMap).map(ForwardTarget.fromMap).toList(),
      selectedSmsSim: _asNullableString(map['selectedSmsSim']),
      smtp: map['smtp'] == null
          ? null
          : SmtpSettings.fromMap(_asMap(map['smtp'])),
      hasData: true,
    );
  }

  final List<ForwardTarget> smsTargets;
  final List<ForwardTarget> emailTargets;
  final List<ForwardTarget> httpTargets;
  final String? selectedSmsSim;
  final SmtpSettings? smtp;
  final bool hasData;

  String get signature {
    return [
      smsTargets.map((target) => target.value).join(','),
      emailTargets.map((target) => target.value).join(','),
      httpTargets.map((target) => target.value).join(','),
      selectedSmsSim ?? '',
      smtp?.signature ?? '',
      hasData.toString(),
    ].join('|');
  }
}

class CommandsConfig {
  const CommandsConfig({
    this.callEnabled = true,
    this.smsEnabled = true,
    this.trustedNumbers = const [],
    this.hasData = false,
  });

  factory CommandsConfig.fromMap(Map<String, Object?> map) {
    if (map.isEmpty) {
      return const CommandsConfig();
    }
    return CommandsConfig(
      callEnabled: map['callEnabled'] != false,
      smsEnabled: map['smsEnabled'] != false,
      trustedNumbers: _asList(
        map['trustedNumbers'],
      ).map(_asMap).map(TrustedNumber.fromMap).toList(),
      hasData: true,
    );
  }

  final bool callEnabled;
  final bool smsEnabled;
  final List<TrustedNumber> trustedNumbers;
  final bool hasData;
}

class SimCardInfo {
  const SimCardInfo({
    required this.subscriptionId,
    required this.slotIndex,
    required this.displayName,
    required this.carrierName,
    required this.number,
  });

  factory SimCardInfo.fromMap(Map<String, Object?> map) {
    return SimCardInfo(
      subscriptionId: _asInt(map['subscriptionId']),
      slotIndex: _asInt(map['slotIndex']),
      displayName: _asString(map['displayName'], fallback: '未命名卡'),
      carrierName: _asString(map['carrierName'], fallback: '未知运营商'),
      number: _asString(map['number'], fallback: '未读取号码'),
    );
  }

  final int subscriptionId;
  final int slotIndex;
  final String displayName;
  final String carrierName;
  final String number;

  String get label {
    return '$displayName · $number';
  }
}

class LogEvent {
  const LogEvent({
    required this.title,
    required this.detail,
    required this.kind,
    required this.type,
    required this.source,
    required this.timestamp,
    this.from,
    this.to,
    this.content,
    this.commandType,
    this.commandContent,
  });

  factory LogEvent.fromMap(Map<String, Object?> map) {
    final type = _asString(map['type'], fallback: 'unknown');
    final timestamp =
        DateTime.tryParse(_asString(map['timestamp'])) ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return LogEvent(
      title: _eventTitle(type),
      detail: _asString(map['detail'], fallback: _eventDetail(type)),
      kind: _eventKind(type),
      type: type,
      source: _asString(map['source']),
      timestamp: timestamp,
      from: _asNullableString(map['from']),
      to: _asNullableString(map['to']),
      content: _asNullableString(map['content']),
      commandType: _asNullableString(map['commandType']),
      commandContent: _asNullableString(map['commandContent']),
    );
  }

  final String title;
  final String detail;
  final EventKind kind;
  final String type;
  final String source;
  final DateTime timestamp;
  final String? from;
  final String? to;
  final String? content;
  final String? commandType;
  final String? commandContent;

  DateTime get localTimestamp => timestamp.toLocal();

  String get timeLabel {
    final local = localTimestamp;
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String get dateTimeLabel {
    final local = localTimestamp;
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute:$second';
  }

  bool get hasStructuredDetail {
    return from != null ||
        to != null ||
        commandType != null ||
        commandContent != null ||
        content != null;
  }

  bool get canOpenDetail {
    return (commandContent?.length ?? content?.length ?? 0) > 48;
  }

  List<({String label, String value})> get detailRows {
    final rows = <({String label, String value})>[
      (label: '时间', value: dateTimeLabel),
    ];
    if (from != null) {
      rows.add((
        label: type == 'call_received' ? '来电号码' : '发送号码',
        value: from!,
      ));
    }
    if (to != null) {
      rows.add((label: '接收号码', value: to!));
    }
    if (commandType != null) {
      rows.add((label: '指令类型', value: commandType!));
    }
    if (commandContent != null) {
      rows.add((label: '指令内容', value: commandContent!));
    }
    if (content != null) {
      rows.add((
        label: type == 'sms_command' ? '指令内容' : '短信内容',
        value: content!,
      ));
    }
    return rows;
  }
}

Map<String, Object?> _asMap(Object? value) {
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return const <String, Object?>{};
}

List<Object?> _asList(Object? value) {
  if (value is List) {
    return value.cast<Object?>();
  }
  return const <Object?>[];
}

String _asString(Object? value, {String fallback = ''}) {
  final text = value?.toString() ?? '';
  return text.isEmpty ? fallback : text;
}

String? _asNullableString(Object? value) {
  final text = value?.toString() ?? '';
  return text.isEmpty ? null : text;
}

int _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '') ?? -1;
}

int? _asNullableInt(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '');
}

String _eventTitle(String type) {
  return switch (type) {
    'sms_received' => '收到短信',
    'sms_history' => '短信历史',
    'call_received' => '电话呼入',
    'call_out_command' => '电话呼出',
    'sms_forwarded' => '短信已转发',
    'sms_command' => '收到指令',
    'sms_sent_command' => '发送短信',
    'operation_log' => '业务日志',
    'agent_connection' => 'Sora 连接',
    'sms_pipeline_debug' => '短信后台链路',
    _ => '系统事件',
  };
}

String _eventDetail(String type) {
  return switch (type) {
    'sms_received' => '普通短信事件',
    'sms_history' => '历史短信事件',
    'call_received' => '电话呼入事件',
    'call_out_command' => '电话呼出事件',
    'sms_forwarded' => '短信转发事件',
    'sms_command' => '短信指令事件',
    'sms_sent_command' => '指令发送短信事件',
    'operation_log' => '业务动作事件',
    'sms_pipeline_debug' => '短信后台调试事件',
    _ => '未分类事件',
  };
}

EventKind _eventKind(String type) {
  return switch (type) {
    'sms_forwarded' || 'sms_received' || 'sms_history' => EventKind.success,
    'sms_command' ||
    'sms_sent_command' ||
    'call_out_command' => EventKind.command,
    _ => EventKind.warning,
  };
}

enum EventKind {
  success(Color(0xFF15803D)),
  command(Color(0xFF2563EB)),
  warning(Color(0xFFB45309));

  const EventKind(this.color);

  final Color color;
}
