class WifiPermissions {
  const WifiPermissions({
    required this.preciseLocationGranted,
    required this.backgroundLocationGranted,
    required this.locationEnabled,
  });

  factory WifiPermissions.fromMap(Map<String, Object?> map) => WifiPermissions(
    preciseLocationGranted: map['preciseLocationGranted'] == true,
    backgroundLocationGranted: map['backgroundLocationGranted'] == true,
    locationEnabled: map['locationEnabled'] == true,
  );

  final bool preciseLocationGranted;
  final bool backgroundLocationGranted;
  final bool locationEnabled;
}
