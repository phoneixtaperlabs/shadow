import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'autopilot_plugin_platform_interface.dart';

/// An implementation of [AutopilotPluginPlatform] that uses method channels.
class EventChannelAutopilotPlugin extends AutopilotPluginPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final resultEventChannel = const EventChannel('autopilot_plugin/result');
  final errorEventChannel = const EventChannel('autopilot_plugin/error');

  @override
  Stream<dynamic> get resultEventStream => resultEventChannel.receiveBroadcastStream();

  @override
  Stream<dynamic> get errorEventStream => errorEventChannel.receiveBroadcastStream();
}
