import Foundation
import OSLog
import Combine

// MARK: - Event Models
protocol AutopilotEvent {
    func toDictionary() -> [String: Any]
}

struct MeetingStartedEvent: AutopilotEvent {
    let platforms: [PlatformInfo]
    
    struct PlatformInfo {
        let id: String
        let name: String
        let microphoneBundleIDs: [String]?
        let activeBrowsers: [String]?
        
        func toDictionary() -> [String: Any] {
            var dict: [String: Any] = [
                "id": id,
                "name": name
            ]
            
            // 값이 있을 때만 추가
            if let bundleIDs = microphoneBundleIDs {
                dict["microphoneBundleIDs"] = bundleIDs
            }
            
            if let browsers = activeBrowsers {
                dict["activeBrowsers"] = browsers
            }
            
            
            return dict
        }
    }
    
    func toDictionary() -> [String: Any] {
        return [
            "isInMeeting": true,
            "platforms": platforms.map { $0.toDictionary() }
        ]
    }
}

struct MeetingEndedEvent: AutopilotEvent {
    func toDictionary() -> [String: Any] {
        return ["isInMeeting": false]
    }
}

// MARK: - Meeting State
struct MeetingState {
    let platform: SupportedPlatform
    let hasWindow: Bool
    let hasMicrophone: Bool
    let hasCamera: Bool
    let startTime: Date
    let hostBrowser: SupportedPlatform? // Only for web platforms - which browser is hosting
    
    var isActive: Bool {
        if platform.id == PlatformID.goTo.rawValue {
            return hasWindow
        }
        
        // Desktop apps: just need microphone
        // Web apps: need window + microphone (via browser)
        switch platform.type {
        case .desktop:
            return hasMicrophone
        case .web:
            return hasWindow && hasMicrophone
        case .browser:
            // Browsers themselves are never "active meetings"
            return false
        }
    }
}

// MARK: - AutopilotService Main Definition
final class AutopilotService: NSObject {
    static let shared = AutopilotService()
    
    // MARK: - Services
    private let windowMonitor = WindowMonitorService.shared
    private let avMonitor = AVDeviceMonitorService.shared
    private let resultStream = AutopilotResultStream.shared
    
    // MARK: - State Properties
    private var meetingStates: [String: MeetingState] = [:] // Key: platform.id
    private var isInMeeting: Bool = false
    private var activeBrowserMicrophones: Set<SupportedPlatform> = []
    
    // MARK: - Utilities
    private let logger = Logger(subsystem: "com.shadow.autopilot", category: "Autopilot")
    private let stateQueue = DispatchQueue(label: "com.yourapp.autopilot.state")
    private var cancellables = Set<AnyCancellable>()
    
    private static let queueKey = DispatchSpecificKey<Void>()
    
    // MARK: - Initialization
    private override init() {
        super.init()
        stateQueue.setSpecific(key: Self.queueKey, value: ())
        setupSubscriptions()
    }
    
    private func verifyStateQueue(file: String = #file, line: Int = #line, function: String = #function) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            print("✅ [\(function)] Correctly running on stateQueue.")
        } else {
            let currentQueueLabel = String(cString: __dispatch_queue_get_label(nil), encoding: .utf8) ?? "unknown"
            print("❌ [\(function)] NOT running on stateQueue. Current queue: '\(currentQueueLabel)'")
            
            // 개발 중에는 assertionFailure로 바로 크래시시킬 수도 있음
            // assertionFailure("Must be called on stateQueue")
        }
    }
    
    private func setupSubscriptions() {
        // Window events
        windowMonitor.windowEventPublisher
            .receive(on: stateQueue)
            .sink { [weak self] event in
                self?.handleWindowEvent(event)
            }
            .store(in: &cancellables)
            
        // AV device events
        avMonitor.deviceEventPublisher
            .receive(on: stateQueue)
            .sink { [weak self] event in
                self?.handleAVEvent(event)
            }
            .store(in: &cancellables)
            
        // Error handling
        Publishers.Merge(
            windowMonitor.errorPublisher,
            avMonitor.errorPublisher
        )
        .receive(on: DispatchQueue.main)
        .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
        .sink { [weak self] error in
            self?.handleError(error)
        }
        .store(in: &cancellables)
    }
}

// MARK: - Public API
extension AutopilotService {
    func startMonitoring() {
        logger.info("Starting Autopilot monitoring")
        AutopilotLogger.shared.info("Starting Autopilot Monitoring")
        
        windowMonitor.startMonitoring()
        avMonitor.startMonitoring()
    }
    
    func stopMonitoring() {
        logger.info("Stopping Autopilot monitoring")
        
        windowMonitor.stopMonitoring()
        avMonitor.stopMonitoring()
        
        stateQueue.async { [weak self] in
            self?.meetingStates.removeAll()
            self?.activeBrowserMicrophones.removeAll()
            self?.isInMeeting = false
            self?.cancellables.removeAll()
        }
    }

    var isMeetingActive: Bool {
        stateQueue.sync { isInMeeting }
    }
    
    var activeMeetingPlatforms: [SupportedPlatform] {
        stateQueue.sync {
            meetingStates.values
                .filter { $0.isActive }
                .map { $0.platform }
        }
    }
    
    func meetingState(for platformId: String, hostBrowser: SupportedPlatform? = nil) -> MeetingState? {
        stateQueue.sync {
            let platform = SupportedPlatform.platform(for: PlatformID(rawValue: platformId) ?? .googleMeet)
            guard let platform = platform else { return nil }
            
            let key = createStateKey(platform: platform, hostBrowser: hostBrowser)
            return meetingStates[key]
        }
    }
    
    func meetingStates(for platformId: String) -> [MeetingState] {
        stateQueue.sync {
            return meetingStates.values.filter { $0.platform.id == platformId }
        }
    }
    
    var allMeetingStates: [String: MeetingState] {
        stateQueue.sync { meetingStates }
    }
}

// MARK: - Event Handlers
extension AutopilotService {
    private func handleWindowEvent(_ event: WindowEvent) {
        verifyStateQueue()
        
        switch event {
        case .windowsDetected(let windows):
            logger.debug("Window monitor detected \(windows.count) new meeting window(s)")
            updatePlatformWindows(windows: windows, isAdding: true)
            
        case .windowsEnded(let windows):
            logger.debug("Window monitor detected \(windows.count) ended meeting window(s)")
            handleWindowsEnded(windows: windows)
        }
    }
    
    private func handleAVEvent(_ event: AVDeviceEvent) {
        switch event {
        case .microphoneChanged(let platforms):
            logger.debug("AV monitor detected microphone usage by \(platforms.count) platform(s)")
            updatePlatformMicrophone(platforms: platforms)
            
        case .cameraChanged(let platforms):
            logger.debug("AV monitor detected camera usage by \(platforms.count) platform(s)")
            updatePlatformCamera(platforms: platforms)
        }
    }
    
    private func handleError(_ error: Error) {
        logger.error("Monitoring error: \(error.localizedDescription)")
        
        let errorDict: [String: Any] = [
            "error": true,
            "message": error.localizedDescription,
            "code": String(describing: error)
        ]
        resultStream.sendEvent(errorDict)
    }
    
    private func handleWindowsEnded(windows: Set<WindowInfo>) {
        var windowsToProcess: Set<WindowInfo> = []
        
        for window in windows {
            if let bundleID = window.bundleIdentifier,
               let browserPlatform = SupportedPlatform.from(bundleID: bundleID),
               browserPlatform.type == .browser {
                
                if activeBrowserMicrophones.contains(browserPlatform) {
                    logger.info("Ignoring window close for \(window.platform?.name ?? "N/A") - browser mic still active")
                    continue
                }
            }
            
            windowsToProcess.insert(window)
        }
        
        if !windowsToProcess.isEmpty {
            updatePlatformWindows(windows: windowsToProcess, isAdding: false)
        }
    }
}

// MARK: - State Management
extension AutopilotService {
    private func updateMeetingState() {
        let wasInMeeting = isInMeeting
        let activeMeetings = meetingStates.values.filter { $0.isActive }
        isInMeeting = !activeMeetings.isEmpty
        
        logger.debug("Current meeting states:")
        for (_, state) in meetingStates {
            let browserInfo = state.hostBrowser != nil ? state.hostBrowser!.name : "N/A"
            logger.debug("  - \(state.platform.name): window=\(state.hasWindow), mic=\(state.hasMicrophone), browser=\(browserInfo), active=\(state.isActive)")
        }
        
        if !activeMeetings.isEmpty {
            let platforms = activeMeetings.map { $0.platform.name }.joined(separator: ", ")
            logger.info("✅ Active meetings: \(platforms)")
        }
        
        verifyStateQueue()
        
        if isInMeeting != wasInMeeting {
            if isInMeeting {
                handleMeetingStart(platforms: activeMeetings.map { $0.platform })
            } else {
                handleMeetingEnd()
            }
        }
    }
    
    private func handleMeetingStart(platforms: [SupportedPlatform]) {
        let platformNames = platforms.map { $0.name }.joined(separator: ", ")
        logger.info("🟢 Meeting STARTED - Platform(s): \(platformNames)")
        
        AutopilotLogger.shared.info("🟢 Meeting STARTED - Platform(s): \(platformNames)")
        
        AutopilotLogger.shared.info("Browser Microphone")
        
        let platformInfos = platforms.map { platform in
            MeetingStartedEvent.PlatformInfo(id: platform.id, name: platform.name, microphoneBundleIDs: platform.microphoneBundleIDs, activeBrowsers: platform.type == .web ? activeBrowserMicrophones.map {$0.name} : nil)
        }
        let event = MeetingStartedEvent(platforms: platformInfos)
        
        AutopilotLogger.shared.info("🟢  Meeting STARTED - Event :\(event.toDictionary())")
        
        DispatchQueue.main.async {
            self.resultStream.sendEvent(event.toDictionary())
        }
    }
    
    private func handleMeetingEnd() {
        logger.info("🔴 Meeting ENDED")
        
        AutopilotLogger.shared.info("🔴 Meeting ENDED")
        
        let event = MeetingEndedEvent()
        
        AutopilotLogger.shared.info("🔴 Meeting ENDED Event: \(event)")
        
        DispatchQueue.main.async {
            self.resultStream.sendEvent(event.toDictionary())
        }
    }

    private func updatePlatformWindows(windows: Set<WindowInfo>, isAdding: Bool) {
        verifyStateQueue()
        
        // stateQueue.async 블록은 원래 코드에 있었으므로 여기에 추가합니다.
            for window in windows {
                guard let platform = window.platform else { continue }
                
                if platform.type == .browser {
                    continue
                }
                
                if isAdding {
                    var hostBrowser: SupportedPlatform? = nil
                    if platform.type == .web, let windowBundleID = window.bundleIdentifier {
                        hostBrowser = SupportedPlatform.from(bundleID: windowBundleID)
                    }
                    
                    let stateKey = self.createStateKey(platform: platform, hostBrowser: hostBrowser)
                    let hasMic = self.getPlatformMicrophoneState(platform: platform, hostBrowser: hostBrowser)
                    
                    // 💥 수정된 부분: 원본 로직을 그대로 사용합니다.
                    if var state = self.meetingStates[stateKey] {
                        // Update existing state
                        state = MeetingState(
                            platform: platform,
                            hasWindow: true,
                            hasMicrophone: hasMic,
                            hasCamera: state.hasCamera,
                            startTime: state.startTime,
                            hostBrowser: hostBrowser
                        )
                        self.meetingStates[stateKey] = state
                    } else {
                        // Create new state
                        self.meetingStates[stateKey] = MeetingState(
                            platform: platform,
                            hasWindow: true,
                            hasMicrophone: hasMic,
                            hasCamera: false,
                            startTime: Date(),
                            hostBrowser: hostBrowser
                        )
                    }
                    self.logger.debug("Window detected for \(platform.name) (key: \(stateKey))")
                    
                } else {
                    self.removeWindowFromStates(platform: platform, window: window)
                }
            }
            
            self.meetingStates = self.meetingStates.filter { _, state in
                state.hasWindow || state.hasMicrophone || state.hasCamera
            }
            
            self.updateMeetingState()
        
    }

    private func updatePlatformMicrophone(platforms: Set<SupportedPlatform>) {
        // stateQueue.async 블록은 원래 코드에 있었으므로 여기에 추가합니다.
            let browsers = platforms.filter { $0.type == .browser }
            let meetingPlatforms = platforms.filter { $0.type != .browser }
            
            self.activeBrowserMicrophones = browsers
            
            if !browsers.isEmpty {
                let browserNames = browsers.map { $0.name }.joined(separator: ", ")
                self.logger.debug("Browsers with microphone access: \(browserNames)")
            } else {
                self.logger.debug("No browsers have microphone access")
            }
            
            // 💥 수정된 부분: 원본 로직을 그대로 사용합니다.
            var updatedStates: [String: MeetingState] = [:]
            
            for (stateKey, state) in self.meetingStates {
                let updatedState: MeetingState
                
                if state.platform.type == .desktop {
                    let hasMic = meetingPlatforms.contains(state.platform)
                    updatedState = MeetingState(
                        platform: state.platform,
                        hasWindow: state.hasWindow,
                        hasMicrophone: hasMic,
                        hasCamera: state.hasCamera,
                        startTime: state.startTime,
                        hostBrowser: state.hostBrowser
                    )
                } else if state.platform.type == .web {
                    let hasMic = state.hostBrowser != nil && browsers.contains(state.hostBrowser!)
                    let shouldClearBrowser = !state.hasWindow && !hasMic
                    
                    updatedState = MeetingState(
                        platform: state.platform,
                        hasWindow: state.hasWindow,
                        hasMicrophone: hasMic,
                        hasCamera: state.hasCamera,
                        startTime: state.startTime,
                        hostBrowser: shouldClearBrowser ? nil : state.hostBrowser
                    )
                } else {
                    updatedState = state
                }
                
                updatedStates[stateKey] = updatedState
            }
            
            for platform in meetingPlatforms {
                let stateKey = self.createStateKey(platform: platform, hostBrowser: nil)
                
                if updatedStates[stateKey] == nil {
                    updatedStates[stateKey] = MeetingState(
                        platform: platform,
                        hasWindow: false,
                        hasMicrophone: true,
                        hasCamera: false,
                        startTime: Date(),
                        hostBrowser: nil
                    )
                    self.logger.debug("New microphone-only state for \(platform.name)")
                }
            }
            
            self.meetingStates = updatedStates
            
            self.cleanupStaleWebMeetingStates()
            
            self.meetingStates = self.meetingStates.filter { _, state in
                state.hasWindow || state.hasMicrophone || state.hasCamera
            }
            
            self.updateMeetingState()
        
    }

    private func updatePlatformCamera(platforms: Set<SupportedPlatform>) {
        // 💥 수정된 부분: 원본 로직을 그대로 사용합니다.
        let browsers = platforms.filter { $0.type == .browser }
        let meetingPlatforms = platforms.filter { $0.type != .browser }
        
        for (platformId, state) in meetingStates {
            if state.platform.type == .desktop {
                let hasCamera = meetingPlatforms.contains(where: { $0.id == platformId })
                meetingStates[platformId] = MeetingState(
                    platform: state.platform,
                    hasWindow: state.hasWindow,
                    hasMicrophone: state.hasMicrophone,
                    hasCamera: hasCamera,
                    startTime: state.startTime,
                    hostBrowser: state.hostBrowser
                )
            } else if state.platform.type == .web {
                let hasCamera = state.hostBrowser != nil && browsers.contains(state.hostBrowser!)
                meetingStates[platformId] = MeetingState(
                    platform: state.platform,
                    hasWindow: state.hasWindow,
                    hasMicrophone: state.hasMicrophone,
                    hasCamera: hasCamera,
                    startTime: state.startTime,
                    hostBrowser: state.hostBrowser
                )
            }
        }
        
        logger.debug("Camera state updated")
    }

    private func cleanupStaleWebMeetingStates() {
        let currentWindows = windowMonitor.activeMeetingWindows
        
        var validWebStateKeys: Set<String> = []
        
        for window in currentWindows {
            guard let platform = window.platform,
                  platform.type == .web,
                  let windowBundleID = window.bundleIdentifier,
                  let hostBrowser = SupportedPlatform.from(bundleID: windowBundleID) else {
                continue
            }
            
            let stateKey = createStateKey(platform: platform, hostBrowser: hostBrowser)
            validWebStateKeys.insert(stateKey)
        }
        
        var staleMeetingStates: [String] = []
        
        for (stateKey, state) in meetingStates {
            if state.platform.type == .web && state.hasWindow {
                if !validWebStateKeys.contains(stateKey) {
                    staleMeetingStates.append(stateKey)
                    logger.info("Removing stale web meeting state: \(state.platform.name) in \(state.hostBrowser?.name ?? "unknown browser")")
                }
            }
        }
        
        for staleKey in staleMeetingStates {
            meetingStates.removeValue(forKey: staleKey)
        }
    }
    
    private func removeWindowFromStates(platform: SupportedPlatform, window: WindowInfo) {
        if platform.type == .web, let windowBundleID = window.bundleIdentifier,
           let hostBrowser = SupportedPlatform.from(bundleID: windowBundleID) {
            
            let stateKey = createStateKey(platform: platform, hostBrowser: hostBrowser)
            
            if var state = meetingStates[stateKey] {
                let stillHasMic = activeBrowserMicrophones.contains(hostBrowser)
                
                state = MeetingState(
                    platform: platform,
                    hasWindow: false,
                    hasMicrophone: stillHasMic,
                    hasCamera: state.hasCamera,
                    startTime: state.startTime,
                    hostBrowser: stillHasMic ? hostBrowser : nil
                )
                meetingStates[stateKey] = state
                logger.debug("Window removed for \(platform.name) (key: \(stateKey)), mic still active: \(stillHasMic)")
            }
            
        } else {
            let stateKey = createStateKey(platform: platform, hostBrowser: nil)
            
            if var state = meetingStates[stateKey] {
                state = MeetingState(
                    platform: platform,
                    hasWindow: false,
                    hasMicrophone: false,
                    hasCamera: false,
                    startTime: state.startTime,
                    hostBrowser: nil
                )
                meetingStates[stateKey] = state
                logger.debug("Window removed for \(platform.name)")
            }
        }
    }
}

// MARK: - Private Helpers
extension AutopilotService {
    private func createStateKey(platform: SupportedPlatform, hostBrowser: SupportedPlatform?) -> String {
        if platform.type == .web, let browser = hostBrowser {
            return "\(platform.id)@\(browser.id)"
        } else {
            return platform.id
        }
    }

    private func getPlatformMicrophoneState(platform: SupportedPlatform, hostBrowser: SupportedPlatform?) -> Bool {
        switch platform.type {
        case .desktop:
            return activeBrowserMicrophones.contains(platform)
        case .web:
            return hostBrowser != nil && activeBrowserMicrophones.contains(hostBrowser!)
        case .browser:
            return false
        }
    }
}
