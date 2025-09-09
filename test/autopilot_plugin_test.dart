import 'package:flutter_test/flutter_test.dart';
import 'package:autopilot_plugin/autopilot_plugin.dart';
import 'package:autopilot_plugin/autopilot_plugin_platform_interface.dart';
import 'package:autopilot_plugin/autopilot_plugin_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockAutopilotPluginPlatform
    with MockPlatformInterfaceMixin
    implements AutopilotPluginPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final AutopilotPluginPlatform initialPlatform = AutopilotPluginPlatform.instance;

  test('$MethodChannelAutopilotPlugin is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelAutopilotPlugin>());
  });

  test('getPlatformVersion', () async {
    AutopilotPlugin autopilotPlugin = AutopilotPlugin();
    MockAutopilotPluginPlatform fakePlatform = MockAutopilotPluginPlatform();
    AutopilotPluginPlatform.instance = fakePlatform;

    expect(await autopilotPlugin.getPlatformVersion(), '42');
  });
}
