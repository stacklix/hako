import 'package:flutter/services.dart';

import '../models/app_models.dart';
import '../models/agent_models.dart';
import '../models/system_settings.dart';
import '../models/wifi_permissions.dart';

class NamiPlatform {
  static Future<WifiPermissions> getWifiPermissions() async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'getWifiPermissions',
    );
    return WifiPermissions.fromMap(raw ?? const {});
  }

  static Future<void> requestWifiPermissions() =>
      _channel.invokeMethod<void>('requestWifiPermissions');
  static Future<void> openWifiLocationSettings() =>
      _channel.invokeMethod<void>('openWifiLocationSettings');
  static const MethodChannel _channel = MethodChannel('doppel/platform');
  static void Function(PlatformSnapshot snapshot)? _snapshotListener;

  static Future<AgentSettings> getAgentSettings() async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'getAgentSettings',
    );
    return AgentSettings.fromMap(raw ?? const {});
  }

  static Future<AgentSettings> generateAgentKey() async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'generateAgentKey',
    );
    return AgentSettings.fromMap(raw ?? const {});
  }

  static Future<AgentSettings> saveAgentSettings(
    Map<String, Object?> settings,
  ) async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'saveAgentSettings',
      settings,
    );
    return AgentSettings.fromMap(raw ?? const {});
  }

  static Future<void> openBatterySettings() =>
      _channel.invokeMethod<void>('openBatterySettings');

  static Future<SystemSettingsStatus> getSystemSettings() async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'getSystemSettings',
    );
    return SystemSettingsStatus.fromMap(raw ?? const {});
  }

  static Future<void> openSystemSettings(SystemSettingsTarget target) =>
      _channel.invokeMethod<void>('openSystemSettings', {
        'target': target.name,
      });

  static void setSnapshotListener(
    void Function(PlatformSnapshot snapshot) listener,
  ) {
    _snapshotListener = listener;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'snapshotChanged') {
        return null;
      }
      _snapshotListener?.call(PlatformSnapshot.fromMap(_asMap(call.arguments)));
      return null;
    });
  }

  static void clearSnapshotListener() {
    _snapshotListener = null;
    _channel.setMethodCallHandler(null);
  }

  static Future<PlatformSnapshot> getSnapshot() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'getSnapshot',
      );
      return PlatformSnapshot.fromMap(raw ?? const <String, Object?>{});
    } on MissingPluginException {
      return const PlatformSnapshot();
    } on PlatformException {
      return const PlatformSnapshot();
    }
  }

  static Future<void> saveConfig(Map<String, Object?> config) async {
    try {
      await _channel.invokeMethod<void>('saveConfig', config);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  static Future<void> requestRequiredPermissions() async {
    try {
      await _channel.invokeMethod<void>('requestRequiredPermissions');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}

Map<String, Object?> _asMap(Object? value) {
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return const <String, Object?>{};
}
