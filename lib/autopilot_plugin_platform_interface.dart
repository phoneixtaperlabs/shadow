import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'autopilot_plugin_method_channel.dart';
import 'autopilot_plugin_event_channel.dart';

abstract class AutopilotPluginPlatform extends PlatformInterface {
  /// Constructs a AutopilotPluginPlatform.
  AutopilotPluginPlatform() : super(token: _token);

  static final Object _token = Object();

  static AutopilotPluginPlatform _instance = MethodChannelAutopilotPlugin();

  static AutopilotPluginPlatform _eventInstance = EventChannelAutopilotPlugin();

  /// The default instance of [AutopilotPluginPlatform] to use.
  ///
  /// Defaults to [MethodChannelAutopilotPlugin].
  static AutopilotPluginPlatform get method => _instance;

  static AutopilotPluginPlatform get event => _eventInstance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [AutopilotPluginPlatform] when
  /// they register themselves.
  static set method(AutopilotPluginPlatform method) {
    PlatformInterface.verifyToken(method, _token);
    _instance = method;
  }

  static set event(AutopilotPluginPlatform event) {
    PlatformInterface.verifyToken(event, _token);
    _eventInstance = event;
  }

  Stream<dynamic> get resultEventStream {
    throw UnimplementedError('resultEventStream has not been implemented.');
  }

  Stream<dynamic> get errorEventStream {
    throw UnimplementedError('errorEventStream has not been implemented.');
  }

  Future<void> showEnabledNotification() async {
    throw UnimplementedError('showEnabledNotification() has not been implemented.');
  }

  Future<void> showAskNotification() async {
    throw UnimplementedError('showAskNotification() has not been implemented.');
  }

  Future<dynamic> startAutopilot() {
    throw UnimplementedError('startAutopilot() has not been implemented.');
  }

  Future<dynamic> stopAutopilot() {
    throw UnimplementedError('stopAutopilot() has not been implemented.');
  }

  Future<dynamic> getSupportedPlatforms() {
    throw UnimplementedError('getSupportedPlatforms() has not been implemented.');
  }

  // 새로 추가
  void setNativeCallHandler(Future<dynamic> Function(MethodCall call)? handler) {
    throw UnimplementedError('setNativeCallHandler() has not been implemented.');
  }
}
