import Foundation
import FlutterMacOS

final class AutopilotErrorStream: NSObject, FlutterStreamHandler {
    static let shared = AutopilotErrorStream()
    private var eventSink: FlutterEventSink?
    private override init() {
        super.init()
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        print("AutopilotErrorStream Service OnListen!!")
        self.eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        print("AutopilotErrorStream Service onCancel!!")
        eventSink = nil
        return nil
    }
    
    func sendEvent(_ event: Any) {
        eventSink?(event)
    }
}
