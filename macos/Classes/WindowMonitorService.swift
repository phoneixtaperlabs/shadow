import Foundation
import CoreGraphics
import OSLog
import Combine

// MARK: - Models
struct WindowInfo: Equatable, Hashable {
    let windowID: CGWindowID
    let title: String
    let ownerName: String
    let ownerPID: pid_t
    let bundleIdentifier: String?
    let platform: SupportedPlatform?
    
    var description: String {
        "\(platform?.name ?? "Unknown"): \(title)"
    }
}

// MARK: - Protocols
protocol WindowMonitoring {
    func startMonitoring()
    func stopMonitoring()
    var isMonitoring: Bool { get }
}

// MARK: - WindowMonitorService
final class WindowMonitorService: WindowMonitoring {
    static let shared = WindowMonitorService()
    
    // MARK: - Publishers
    @Published private(set) var currentMeetingWindows = Set<WindowInfo>()
    
    // Custom publishers for window events
    private let windowEventSubject = PassthroughSubject<WindowEvent, Never>()
    var windowEventPublisher: AnyPublisher<WindowEvent, Never> {
        windowEventSubject.eraseToAnyPublisher()
    }
    
    // Error publisher
    private let errorSubject = PassthroughSubject<MonitoringError, Never>()
    var errorPublisher: AnyPublisher<MonitoringError, Never> {
        errorSubject.eraseToAnyPublisher()
    }
    
    // Combined state publisher
    var meetingWindowsPublisher: AnyPublisher<Set<WindowInfo>, Never> {
        $currentMeetingWindows.eraseToAnyPublisher()
    }
    
    // MARK: - Properties
    private let checkInterval: TimeInterval = 5.0
    private var timer: Timer?
    private let logger = Logger(subsystem: "com.yourapp.windowmonitor", category: "WindowMonitor")
    private let stateQueue = DispatchQueue(label: "com.yourapp.windowmonitor.state")
    
    private init() {}
    
    // MARK: - Public Properties
    var isMonitoring: Bool {
        timer != nil
    }
    
    var activeMeetingWindows: Set<WindowInfo> {
        stateQueue.sync { currentMeetingWindows }
    }
    
    var activePlatforms: Set<SupportedPlatform> {
        stateQueue.sync {
            Set(currentMeetingWindows.compactMap { $0.platform })
        }
    }
    
    // MARK: - Public Methods
    func startMonitoring() {
        guard !isMonitoring else {
            logger.warning("Window monitoring already active")
            return
        }
        
        logger.info("Starting window monitoring")
        
        // Perform initial check
        checkWindows()
        
        // Start timer on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timer = Timer.scheduledTimer(
                withTimeInterval: self.checkInterval,
                repeats: true
            ) { _ in
                self.checkWindows()
            }
        }
    }
    
    func stopMonitoring() {
        guard isMonitoring else {
            logger.warning("Window monitoring not active")
            return
        }
        
        logger.info("Stopping window monitoring")
        
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
        
        // Clear state
        stateQueue.sync {
            currentMeetingWindows.removeAll()
        }
    }
    
    // MARK: - Private Methods
    private func checkWindows() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            
            let meetingWindows = self.fetchMeetingWindows()
            self.updateState(with: meetingWindows)
        }
    }
    
    private func updateState(with newWindows: Set<WindowInfo>) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            
            let oldWindows = self.currentMeetingWindows
            self.currentMeetingWindows = newWindows
            
            // Calculate changes
            let addedWindows = newWindows.subtracting(oldWindows)
            let removedWindows = oldWindows.subtracting(newWindows)
            
            // Emit events if there are changes
            if !addedWindows.isEmpty {
                self.logger.info("New meeting windows: \(addedWindows.map { $0.description }.joined(separator: ", "))")
                DispatchQueue.main.async {
                    self.windowEventSubject.send(.windowsDetected(addedWindows))
                }
            }
            
            if !removedWindows.isEmpty {
                self.logger.info("Ended meeting windows: \(removedWindows.map { $0.description }.joined(separator: ", "))")
                DispatchQueue.main.async {
                    self.windowEventSubject.send(.windowsEnded(removedWindows))
                }
            }
        }
    }
    
    private func getBundleIdentifier(from pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }
        return app.bundleIdentifier
    }
    
    private func fetchMeetingWindows() -> Set<WindowInfo> {
        var meetingWindows = Set<WindowInfo>()
        
//        let targetBundleIDs: Set<String> = [
//            "com.microsoft.teams2"
//        ]
        
//        let targetBundleIDs: Set<String> = [
//            "com.google.Chrome",
//            "com.apple.Safari",
//            "com.microsoft.edgemac",
//            "org.mozilla.firefox",
//            "ai.perplexity.comet",
//            "com.brave.Browser",
//            "app.zen-browser.zen",
//            "company.thebrowser.dia",
//            "com.openai.atlas",
//            "com.tinyspeck.slackmacgap"
//        ]

        let options = CGWindowListOption(arrayLiteral: [.optionAll, .excludeDesktopElements])
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            logger.error("Failed to get window list")
            AutopilotLogger.shared.error("Failed to get SC W List.")
            errorSubject.send(.cannotFetchWindowList)
            return meetingWindows
        }
        
        for windowDict in windowList {
            guard let windowID = windowDict[kCGWindowNumber as String] as? CGWindowID,
                  let windowTitle = windowDict[kCGWindowName as String] as? String,
                  !windowTitle.isEmpty,
                  let ownerName = windowDict[kCGWindowOwnerName as String] as? String,
                  let ownerPID = windowDict[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }
            
            if let boundsDict = windowDict[kCGWindowBounds as String] as? [String: CGFloat],
               let width = boundsDict["Width"],
               let height = boundsDict["Height"],
               width < 100 || height < 100 {
                continue
            }
            
//            let bundleID = getBundleIdentifier(from: ownerPID)
            
            guard let bundleID = getBundleIdentifier(from: ownerPID) else {
                continue
            }
            
//            guard targetBundleIDs.contains(bundleID) else {
//                continue
//            }
//            
//            logger.info("타켓 윈도우 -- \(windowTitle), \(windowID), \(ownerName), \(bundleID)")
            
            if let windowInfo = detectMeetingWindow(
                windowID: windowID,
                title: windowTitle,
                ownerName: ownerName,
                ownerPID: ownerPID,
                bundleIdentifier: bundleID
            ) {
                meetingWindows.insert(windowInfo)
            }
            
            
        }
        
        return meetingWindows
    }
    
    private func detectMeetingWindow(windowID: CGWindowID, title: String, ownerName: String, ownerPID: pid_t, bundleIdentifier: String?) -> WindowInfo? {
        guard let bundleID = bundleIdentifier else { return nil }
        // --- Google Chrome Meet PWA
        if bundleID == BundleID.chromeGoogleMeetPWA && isGoogleMeetPWA(title: title) {
            return WindowInfo(
                windowID: windowID, title: title, ownerName: ownerName, ownerPID: ownerPID,
                bundleIdentifier: BundleID.chrome,
                platform: SupportedPlatform.platform(for: .googleMeetPWA) 
            )
        }
        
        // --- Vivaldi Google Meet PWA
        if bundleID == BundleID.vivaldiGoogleMeetPWA && isGoogleMeetPWA(title: title) {
            return WindowInfo(windowID: windowID, title: title, ownerName: ownerName, ownerPID: ownerPID, bundleIdentifier: BundleID.vivaldi, platform: SupportedPlatform.platform(for: .googleMeetPWAVivaldi))
        }
        
        // --- Case 1: A web meeting running in a browser ---
        if SupportedPlatform.isBrowser(bundleID: bundleID) {
            // First, check for standard web platforms like Google Meet using its keyword.
            if let webPlatform = SupportedPlatform.all.first(where: { $0.type == .web && $0.matches(windowTitle: title) }) {
                return WindowInfo(
                    windowID: windowID, title: title, ownerName: ownerName, ownerPID: ownerPID,
                    bundleIdentifier: bundleID, platform: webPlatform
                )
            }
            
            // Second, check for the special Google Meet format in the Arc browser.
            if bundleID == BundleID.arc && isGoogleMeetFormat(title: title) {
                return WindowInfo(
                    windowID: windowID, title: title, ownerName: ownerName, ownerPID: ownerPID,
                    bundleIdentifier: bundleID, platform: SupportedPlatform.platform(for: .googleMeet)
                )
            }
        }
        
        // --- Case 2: A desktop meeting app that uses window titles ---
        if let desktopPlatform = SupportedPlatform.from(bundleID: bundleID),
           desktopPlatform.type == .desktop,
           desktopPlatform.windowTitleKeywords != nil {
            if desktopPlatform.matches(windowTitle: title) {
                return WindowInfo(
                    windowID: windowID, title: title, ownerName: ownerName, ownerPID: ownerPID,
                    bundleIdentifier: bundleID, platform: desktopPlatform
                )
            }
        }
        
        return nil
    }
}

// MARK: - Special Case Utility Method
extension WindowMonitorService {
    private func isGoogleMeetPWA(title: String) -> Bool {
        // 불필요한 공백 제거
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // "Google Meet - Meet -" 패턴이 포함되어 있으면 미팅 중인 상태로 간주
        return normalizedTitle.localizedCaseInsensitiveContains("Google Meet - Meet -")
    }

    
    // Arc
    private func isGoogleMeetFormat(title: String) -> Bool {
        // Google Meet format: xxx-xxxx-xxx
        let components = title.split(separator: "-")
        return components.count == 3 &&
        components[0].count == 3 &&
        components[1].count == 4 &&
        components[2].count == 3 &&
        components.allSatisfy { $0.allSatisfy { $0.isLetter } }
    }
    
    private func detectTeamsWebWindowTitle(_ title: String) -> Bool {
        // Teams web format: "Chat | ... | Microsoft Teams"
        let components = title.components(separatedBy: " | ")
        
        guard components.count >= 2 else { return false }
        
        // Check start and end
        let validStarts = ["Chat", "Calendar", "Meeting"]
        return validStarts.contains(components.first ?? "") &&
        components.contains("Microsoft Teams")
    }
}

// MARK: - Convenience Methods
extension WindowMonitorService {
    /// Check if a specific platform has an active meeting window
    func isMeetingActive(for platform: SupportedPlatform) -> Bool {
        activePlatforms.contains(platform)
    }
    
    /// Check if any meeting window is active
    var isAnyMeetingActive: Bool {
        !activeMeetingWindows.isEmpty
    }
    
    /// Get meeting window for a specific platform
    func meetingWindow(for platform: SupportedPlatform) -> WindowInfo? {
        activeMeetingWindows.first { $0.platform?.id == platform.id }
    }
}
