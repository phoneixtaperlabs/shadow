import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'autopilot_plugin_platform_interface.dart';

/// An implementation of [AutopilotPluginPlatform] that uses method channels.
class MethodChannelAutopilotPlugin extends AutopilotPluginPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('autopilot_plugin');

  @override
  Future<void> showEnabledNotification() async {
    await methodChannel.invokeMethod('showEnabledNotification');
  }

  @override
  Future<void> showAskNotification() async {
    await methodChannel.invokeMethod('showAskNotification');
  }

  @override
  Future<dynamic> startAutopilot() async {
    final result = await methodChannel.invokeMethod('startAutopilot');
    return result;
  }

  @override
  Future<dynamic> stopAutopilot() async {
    final result = await methodChannel.invokeMethod('stopAutopilot');
    return result;
  }

  @override
  Future<dynamic> getSupportedPlatforms() async {
    final platforms = await methodChannel.invokeMethod('getSupportedPlatforms');
    return platforms;
  }

  // 새로 추가: Swift에서 오는 호출을 받기 위한 메서드
  void setNativeCallHandler(Future<dynamic> Function(MethodCall call)? handler) {
    methodChannel.setMethodCallHandler(handler);
  }
}
