class SystemSettingsStatus {
  const SystemSettingsStatus({
    required this.autoStartAvailable,
    required this.backgroundAvailable,
    required this.batteryExempt,
    required this.notificationsEnabled,
  });

  factory SystemSettingsStatus.fromMap(Map<String, Object?> map) {
    return SystemSettingsStatus(
      autoStartAvailable: map['autoStartAvailable'] == true,
      backgroundAvailable: map['backgroundAvailable'] == true,
      batteryExempt: map['batteryExempt'] == true,
      notificationsEnabled: map['notificationsEnabled'] == true,
    );
  }

  final bool autoStartAvailable;
  final bool backgroundAvailable;
  final bool batteryExempt;
  final bool notificationsEnabled;
}

enum SystemSettingsTarget {
  autoStart,
  background,
  battery,
  notifications,
  application,
}
