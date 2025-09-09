import 'package:flutter/services.dart';

import 'autopilot_plugin_platform_interface.dart';

class AutopilotPlugin {
  Stream<dynamic> get resultEventStream => AutopilotPluginPlatform.event.resultEventStream;
  Stream<dynamic> get errorEventStream => AutopilotPluginPlatform.event.errorEventStream;

  Future<void> showEnabledNotification() async {
    await AutopilotPluginPlatform.method.showEnabledNotification();
  }

  Future<void> showAskNotification() async {
    await AutopilotPluginPlatform.method.showAskNotification();
  }

  Future<dynamic> startAutopilot() {
    return AutopilotPluginPlatform.method.startAutopilot();
  }

  Future<dynamic> stopAutopilot() {
    return AutopilotPluginPlatform.method.stopAutopilot();
  }

  Future<dynamic> getSupportedPlatforms() {
    return AutopilotPluginPlatform.method.getSupportedPlatforms();
  }

  void setNativeCallHandler(Future<dynamic> Function(MethodCall call)? handler) {
    AutopilotPluginPlatform.method.setNativeCallHandler(handler);
  }
}
