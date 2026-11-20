class AgentSettings {
  const AgentSettings({
    this.enabled = false,
    this.server = '',
    this.username = '',
    this.allowSms = false,
    this.allowCalls = false,
    this.publicKey = '',
    this.keyId = '',
    this.batteryExempt = false,
    this.state = 'disconnected',
    this.message = '未连接',
    this.agentId = '',
  });

  factory AgentSettings.fromMap(Map<String, Object?> map) {
    final status = map['status'] is Map ? map['status'] as Map : const {};
    return AgentSettings(
      enabled: map['enabled'] == true,
      server: map['server'] as String? ?? '',
      username: map['username'] as String? ?? '',
      allowSms: map['allowSms'] == true,
      allowCalls: map['allowCalls'] == true,
      publicKey: map['publicKey'] as String? ?? '',
      keyId: map['keyId'] as String? ?? '',
      batteryExempt: map['batteryExempt'] == true,
      state: status['state'] as String? ?? 'disconnected',
      message: status['message'] as String? ?? '未连接',
      agentId: status['agentId'] as String? ?? '',
    );
  }

  final bool enabled;
  final String server;
  final String username;
  final bool allowSms;
  final bool allowCalls;
  final String publicKey;
  final String keyId;
  final bool batteryExempt;
  final String state;
  final String message;
  final String agentId;
}
