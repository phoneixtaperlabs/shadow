import Cocoa
import FlutterMacOS

public class AutopilotPlugin: NSObject, FlutterPlugin {
    
    private static var methodChannel: FlutterMethodChannel?
    
    public static var shadowIconImage: NSImage?
    
    override init() {
        super.init()
        print("AutopilotPlugin: init() - \(Date())")
        print("AutopilotPlugin: 메모리 주소 - \(Unmanaged.passUnretained(self).toOpaque())")
    }
    
    deinit {
        print("AutopilotPlugin: deinit() - \(Date())")
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        print("AutopilotPlugin: register() 호출됨")
        let channel = FlutterMethodChannel(name: "autopilot_plugin", binaryMessenger: registrar.messenger)
        methodChannel = channel
        let instance = AutopilotPlugin()
        print("AutopilotPlugin: 인스턴스 생성 후 등록")
        AutopilotLogger.configure(
            subsystem: "com.taperlabs.shadow",
            category: "autopilot",
            retentionDays: 3,
            minimumLogLevel: .info
        )
        registrar.addMethodCallDelegate(instance, channel: channel)
        
        
        let autopilotEventChannel = FlutterEventChannel(
            name: "autopilot_plugin/result",
            binaryMessenger: registrar.messenger
        )
        autopilotEventChannel.setStreamHandler(AutopilotResultStream.shared)
        
        loadShadowIcon(registrar: registrar)
    }
    
    private static func loadShadowIcon(registrar: FlutterPluginRegistrar) {
        let assetPath = "assets/images/icons/shadow_brand.svg"
        let assetKey = registrar.lookupKey(forAsset: assetPath)
        // 앱 번들의 기본 경로와 assetKey를 직접 조합하여 전체 파일 경로를 생성
        let bundlePath = Bundle.main.bundlePath
        let filePath = (bundlePath as NSString).appendingPathComponent(assetKey)
        
        // 파일이 실제로 존재하는지 확인
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("❌ ERROR: File does not exist at constructed path: \(filePath)")
            return
        }
        
        do {
            // 이제 이 filePath를 사용해 데이터를 읽기
            let fileUrl = URL(fileURLWithPath: filePath)
            let data = try Data(contentsOf: fileUrl)
            self.shadowIconImage = NSImage(data: data)
            print("✅ SVG icon 'shadow.svg' loaded as NSImage.")
        } catch {
            print("❌ ERROR: Failed to create NSImage from SVG asset: \(error)")
        }
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("AutopilotPlugin: handle() 호출됨 - 메서드: \(call.method)")
        switch call.method {
            
        case "startAutopilot":
            print("Start Autopilot")
            AutopilotService.shared.startMonitoring()
            result(nil)
            
        case "stopAutopilot":
            print("Stop Autopilot")
            AutopilotService.shared.stopMonitoring()
            result(nil)
        case "showEnabledNotification":
            Task { @MainActor in
                NotiWindowManager.shared.showNotiWindow(type: .enabled)
                result(nil)
            }
        case "showAskNotification":
            Task { @MainActor in
                NotiWindowManager.shared.showNotiWindow(type: .ask)
                result(nil)
            }
        case "getSupportedPlatforms":
            let supportedPlatforms = SupportedPlatform.categorizedPlatformNames
            result(supportedPlatforms)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}


extension AutopilotPlugin {
    // Swift → Flutter 호출을 위한 헬퍼 메서드
    static func sendToFlutter(_ method: ListenAction, data: Any? = nil) {
        methodChannel?.invokeMethod(method.rawValue, arguments: data)
    }
}
