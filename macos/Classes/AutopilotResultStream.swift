import Foundation
import FlutterMacOS

//MARK: - Autopilot Detection Result Stream to Flutter-side
final class AutopilotResultStream: NSObject, FlutterStreamHandler {
    static let shared = AutopilotResultStream()
    private var eventSink: FlutterEventSink?
    private override init() {
        super.init()
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        print("🫨 AutopilotResultStream Service OnListen!!")
        self.eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        print("🤞 AutopilotResultStream Service onCancel!!")
        eventSink = nil
        return nil
    }
    
    func sendEvent(_ event: Any) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(event)
        }
    }
}
