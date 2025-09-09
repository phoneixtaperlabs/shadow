import Foundation
import CoreGraphics
import SwiftUI

enum NotiType {
    case enabled // 'Cancel' 버튼이 있는 경우
    case ask     // 'Listen' 버튼이 있는 경우
    
    // 타입에 따라 다른 부제목을 반환
    var baseSubtitle: String {
        switch self {
        case .enabled:
            return "I'll start listening in "
        case .ask:
            return "Automatically Dismissing in "
        }
    }
    
    // 타입에 따라 다른 버튼 텍스트를 반환
    var buttonText: String {
        switch self {
        case .enabled:
            return "Cancel"
        case .ask:
            return "Listen"
        }
    }
    
    var duration: TimeInterval {
        switch self {
        case .enabled:
            return 3.0 // enabled 타입은 3초
        case .ask:
            return 5.0 // ask 타입은 5초
        }
    }
}

// Flutter에 어떤 행동을 할지 알려주는 Enum
enum ListenAction: String {
    case startListen // "Listen을 시작해라"
    case dismissListen  // "Listen을 중지/취소해라"
}

// 해당 액션이 왜 발생했는지 원인을 알려주는 Enum
enum ActionTrigger: String {
    case userAction // 사용자가 직접 버튼을 눌렀음
    case timeout    // 아무것도 안 해서 창이 시간 초과로 닫혔음
}

struct ListenStatePayload {
    let action: ListenAction
    let trigger: ActionTrigger
    
    // MethodChannel로 전송하기 위해 Dictionary로 변환하는 함수
    func toDictionary() -> [String: String] {
        return [
            "action": self.action.rawValue,   // "startListen" 또는 "stopListen"
            "trigger": self.trigger.rawValue // "userAction" 또는 "timeout"
        ]
    }
}

@MainActor
final class NotiWindowManager {
    static let shared = NotiWindowManager()
    
    private var notiWindowController: NotiWindowController?
    private var targetWindowTimer: Timer?
    private var logger: AutopilotLogger?
    
    private init() {
        Task {
            self.logger = await AutopilotLogger.shared
            self.logger?.info("NotiWindowManager initialized")
        }
    }
    
    deinit {
        Task { [logger = self.logger] in
            // 이제 클로저는 self.logger가 아닌 캡처된 'logger' 변수를 사용합니다.
            // deinit이 끝나도 logger 인스턴스는 유효하므로 안전합니다.
            logger?.info("NotiWindowManager deinit")
        }
        print("NotiWindowManager deinit")
    }
    
    func showNotiWindow(type: NotiType, autoCloseAfter seconds: TimeInterval? = nil, width: CGFloat = 350, height: CGFloat = 70) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        
        let windowWidth: CGFloat = width
        let windowHeight: CGFloat = height
        
        let xPos = screenFrame.maxX - windowWidth - 10
        let yPos = screenFrame.maxY - windowHeight - 20
        
        let customNotiWindow = NSWindow(
            contentRect: NSRect(x: xPos, y: yPos, width: width, height: height),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        configureNotiWindow(customNotiWindow)
        
        let effectiveSeconds = seconds ?? type.duration
        
        // --- ⭐️ 1. 순서 변경: NotiWindowController를 먼저 생성합니다. ⭐️ ---
        notiWindowController = NotiWindowController(
            notiWindow: customNotiWindow,
            type: type,
            onClose: { [weak self] (closedType, wasActionTaken) in
                
                let payload: ListenStatePayload
                
                if !wasActionTaken {
                    print("Window closed without a button click (timeout).")
                    switch closedType {
                    case .enabled:
                        print("Default action for .enabled: Proceeding to listen.")
                        payload = ListenStatePayload(action: .startListen, trigger: .timeout)
                        AutopilotPlugin.sendToFlutter(.startListen, data: payload.toDictionary())
                    case .ask:
                        print("Default action for .ask: Dismissing without action.")
                        payload = ListenStatePayload(action: .dismissListen, trigger: .timeout)
                        AutopilotPlugin.sendToFlutter(.dismissListen, data: payload.toDictionary())
                    }
                }
                self?.handleWindowClosed()
            }
        )
        
        // --- ⭐️ 2. 이제 NotiView를 생성합니다. ⭐️ ---
        // 이 시점에는 self.notiWindowController가 유효한 값을 가지므로,
        // buttonAction 클로저가 올바른 컨트롤러를 캡처할 수 있습니다.
        let contentView = NotiView(
            title: "Meeting Detected",
            baseSubtitle: type.baseSubtitle,
            initialCount: Int(effectiveSeconds),
            buttonText: type.buttonText,
            buttonAction: { [weak self] in
                print("\(type.buttonText) Clicked")
                self?.notiWindowController?.setActionTaken()
                
                let payload: ListenStatePayload
                
                switch type {
                case .enabled:
                    print("Internal logic: Canceling the pending listen action.")
                    payload = ListenStatePayload(action: .dismissListen, trigger: .userAction)
                    AutopilotPlugin.sendToFlutter(.dismissListen, data: payload.toDictionary())
                case .ask:
                    print("Internal logic: Force starting the listen action.")
                    payload = ListenStatePayload(action: .startListen, trigger: .userAction)
                    AutopilotPlugin.sendToFlutter(.startListen, data: payload.toDictionary())
                }
                self?.notiWindowController?.closeWindow()
            }
        )
        
        let hostingView = NSHostingView(rootView: contentView)
        customNotiWindow.contentView = hostingView
        
        notiWindowController?.setupAutoClose(after: effectiveSeconds)
        
        customNotiWindow.makeKeyAndOrderFront(nil)
        customNotiWindow.orderFrontRegardless()
    }
    
    private func configureNotiWindow(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
    }
    
    
    private func handleWindowClosed() {
        print("Window closed callback received")
        notiWindowController = nil
    }
    
    private func cleanupNotiWindow() {
        print("Cleaning up NotiWindow...")

        if let controller = notiWindowController {
            controller.closeWindow()
        }
        notiWindowController = nil
        print("Custom Notification cleanup complete")
    }
}
