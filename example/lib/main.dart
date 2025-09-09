// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:autopilot_plugin/autopilot_plugin.dart';

void main() {
  runApp(const MyApp());
}

// ### [Swift --> Flutter MethodChannel]
enum NativeMethod { startListen, dismissListen }

enum ListenAction { startListen, dismissListen }

enum ActionTrigger { userAction, timeout }

class ListenStatePayload {
  final ListenAction action;
  final ActionTrigger trigger;

  ListenStatePayload({required this.action, required this.trigger});

  // Map을 DTO 객체로 변환하는 핵심 로직
  factory ListenStatePayload.fromJson(Map<String, dynamic> json) {
    // 필수 키가 없는 경우를 대비한 예외 처리
    if (json['action'] == null || json['trigger'] == null) {
      throw FormatException("Missing required keys: action or trigger");
    }

    try {
      // String 값을 해당하는 Enum 값으로 변환
      final action = ListenAction.values.byName(json['action']);
      final trigger = ActionTrigger.values.byName(json['trigger']);

      return ListenStatePayload(action: action, trigger: trigger);
    } catch (e) {
      // Swift에서 보낸 문자열이 Enum에 정의되지 않은 경우 예외 발생
      throw FormatException("Invalid enum value provided: $e");
    }
  }
}

// 1. 문자열을 Enum으로 변환하는 헬퍼 확장(extension) 추가
extension NativeMethodParser on String {
  NativeMethod? toNativeMethod() {
    // Enum의 모든 값을 순회하며 이름이 일치하는 것을 찾아 반환
    for (var method in NativeMethod.values) {
      if (method.name == this) {
        return method;
      }
    }
    return null; // 일치하는 Enum 값이 없으면 null 반환
  }
}

// AutopilotEvent 모델 클래스
class AutopilotEvent {
  // final 키워드를 사용하여 불변(immutable) 객체로 생성
  final bool isInMeeting;
  final List<dynamic>? platforms; // platforms는 없을 수도 있으므로 nullable(?)로 선언

  // 생성자
  AutopilotEvent({required this.isInMeeting, this.platforms});

  static List<dynamic>? _parsePlatforms(dynamic value) {
    if (value is List) {
      return List<dynamic>.from(value);
    }
    return null;
  }

  // Map<String, dynamic> 형태의 데이터를 AutopilotEvent 객체로 변환하는 팩토리 생성자
  // 이 부분이 타입 안정성의 핵심
  factory AutopilotEvent.fromMap(Map<String, dynamic> map) {
    return AutopilotEvent(
      isInMeeting: map['isInMeeting'] == true, // Safe boolean conversion
      platforms: _parsePlatforms(map['platforms']),
    );
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _platformVersion = 'Unknown';
  final _autopilotPlugin = AutopilotPlugin();
  StreamSubscription<dynamic>? autopilotResultStreamSubscription;

  @override
  void initState() {
    super.initState();

    // Swift에서 오는 호출을 받기 위한 핸들러 설정
    _autopilotPlugin.setNativeCallHandler(_handleNativeCall);
    getSupportedPlatforms();
    startAutopilot();
    showAskNotification();
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    print("Swift에서 호출됨: ${call.method}, arguments: ${call.arguments}, type: ${call.arguments.runtimeType}");

    final method = call.method.toNativeMethod();
    if (method == null) {
      print("Unknown method received: ${call.method}");
      return;
    }

    if (call.arguments is! Map) {
      print("Invalid arguments type: ${call.arguments.runtimeType}");
      return;
    }

    final ListenStatePayload payload;
    try {
      final Map<String, dynamic> eventMap = Map<String, dynamic>.from(call.arguments);
      print("Parsed eventMap: $eventMap, type: ${eventMap.runtimeType}");
      payload = ListenStatePayload.fromJson(eventMap);
      print("Action: ${payload.action}, Trigger: ${payload.trigger}");
    } catch (e) {
      print("네이티브 이벤트 처리 중 에러 발생: $e");
      return;
    }

    switch (method) {
      case NativeMethod.startListen:
        setState(() {
          _platformVersion = 'Native Event: ${payload.action}, ${payload.trigger}';
        });
        break;
      case NativeMethod.dismissListen:
        setState(() {
          _platformVersion = 'Native Event: ${payload.action}, ${payload.trigger}';
        });
        break;
    }
  }

  Future<void> showAskNotification() async {
    try {
      await _autopilotPlugin.showAskNotification();
    } on PlatformException catch (e) {
      print("Failed to show permission request notification: '${e.message}'.");
    }
  }

  Future<void> showEnabledNotification() async {
    try {
      await _autopilotPlugin.showEnabledNotification();
    } on PlatformException catch (e) {
      print("Failed to show enabled notification: '${e.message}'.");
    }
  }

  Future<dynamic> startAutopilot() async {
    try {
      final result = await _autopilotPlugin.startAutopilot();
      print("Autopilot monitoring started: $result");
    } on PlatformException catch (e) {
      print("Failed to start autopilot monitoring: '${e.message}'.");
    }

    autopilotResultStreamSubscription = _autopilotPlugin.resultEventStream.listen(
      (event) {
        print("Autopilot result event: $event");

        // 타입을 Map으로 더 유연하게 확인
        if (event is Map) {
          try {
            // Map<Object?, Object?>를 Map<String, dynamic>으로 안전하게 변환
            // 이 과정에서 키가 String이 아니면 런타임 에러가 발생 --> catch에서 잡을 수 있음
            final Map<String, dynamic> eventMap = Map<String, dynamic>.from(event);

            // 타입 캐스팅된 맵을 사용하여 객체를 생성
            final autopilotEvent = AutopilotEvent.fromMap(eventMap);

            if (autopilotEvent.isInMeeting) {
              print("isInMeeting is true. Calling showEnabledNotification...");
              showAskNotification();
            } else {
              print("isInMeeting is ${autopilotEvent.isInMeeting}.");
            }
          } catch (e) {
            // 파싱 또는 변환 과정에서 오류 발생 시 처리
            print("Failed to parse or convert autopilot event: $e");
          }
        } else {
          print("Received event is not a Map: ${event.runtimeType}");
        }
      },
      onError: (error) {
        print("Autopilot error event: $error");
      },
    );
  }

  Future<dynamic> getSupportedPlatforms() async {
    try {
      final platforms = await _autopilotPlugin.getSupportedPlatforms();
      print("Supported platforms 입니다: $platforms");
      return platforms;
    } on PlatformException catch (e) {
      print("Failed to get supported platforms: '${e.message}'.");
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(appBar: AppBar(title: const Text('Plugin example app')), body: Center(child: Text('Running on: $_platformVersion\n'))),
    );
  }
}
