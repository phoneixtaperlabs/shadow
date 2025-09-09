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
        
        func toDictionary() -> [String: Any] {
            return ["id": id, "name": name]
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

// MARK: - AutopilotService
final class AutopilotService: NSObject {
    static let shared = AutopilotService()
    
    // Services
    private let windowMonitor = WindowMonitorService.shared
    private let avMonitor = AVDeviceMonitorService.shared
    private let resultStream = AutopilotResultStream.shared
    
    // State tracking - now only accessed on stateQueue
    private var meetingStates: [String: MeetingState] = [:] // Key: platform.id
    private var isInMeeting: Bool = false
    private var activeBrowserMicrophones: Set<SupportedPlatform> = []
    
    // Logger
    private let logger = Logger(subsystem: "com.shadow.autopilot", category: "Autopilot")
    
    // Queue for thread safety - all state operations happen here
    private let stateQueue = DispatchQueue(label: "com.yourapp.autopilot.state")
    
    // Combine subscriptions
    private var cancellables = Set<AnyCancellable>()
    
    private override init() {
        super.init()
        setupSubscriptions()
    }
    
    // MARK: - Setup
    private func setupSubscriptions() {
        // Window events - processed entirely on serial queue
        windowMonitor.windowEventPublisher
            .receive(on: stateQueue)
            .sink { [weak self] event in
                self?.handleWindowEvent(event)
            }
            .store(in: &cancellables)
        
        // AV device events - processed entirely on serial queue
        avMonitor.deviceEventPublisher
            .receive(on: stateQueue)
            .sink { [weak self] event in
                self?.handleAVEvent(event)
            }
            .store(in: &cancellables)
        
        // Error handling - needs main queue for UI updates
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
    
    // MARK: - Public Methods
    func startMonitoring() {
        logger.info("Starting Autopilot monitoring")
        
        windowMonitor.startMonitoring()
        avMonitor.startMonitoring()
    }
    
    func stopMonitoring() {
        logger.info("Stopping Autopilot monitoring")
        
        windowMonitor.stopMonitoring()
        avMonitor.stopMonitoring()
        
        // State cleanup now happens directly on the queue
        stateQueue.async { [weak self] in
            self?.meetingStates.removeAll()
            self?.activeBrowserMicrophones.removeAll()
            self?.isInMeeting = false
            self?.cancellables.removeAll()
        }
    }
    
    // MARK: - Event Handlers (now called directly on stateQueue)
    private func handleWindowEvent(_ event: WindowEvent) {
        // This method now runs on stateQueue, no additional dispatching needed
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
        // This method now runs on stateQueue, no additional dispatching needed
        switch event {
        case .microphoneChanged(let platforms):
            logger.debug("AV monitor detected microphone usage by \(platforms.count) platform(s)")
            updatePlatformMicrophone(platforms: platforms)
            
        case .cameraChanged(let platforms):
            logger.debug("AV monitor detected camera usage by \(platforms.count) platform(s)")
//            updatePlatformCamera(platforms: platforms)
        }
    }
    
    private func handleError(_ error: Error) {
        // This runs on main queue for UI updates
        logger.error("Monitoring error: \(error.localizedDescription)")
        
        let errorDict: [String: Any] = [
            "error": true,
            "message": error.localizedDescription,
            "code": String(describing: error)
        ]
        resultStream.sendEvent(errorDict)
    }
    
    private func handleWindowsEnded(windows: Set<WindowInfo>) {
        // Already on stateQueue, no need for additional dispatching
        var windowsToProcess: Set<WindowInfo> = []
        
        for window in windows {
            // For browsers, check if mic is still active
            if let bundleID = window.bundleIdentifier,
               let browserPlatform = SupportedPlatform.from(bundleID: bundleID),
               browserPlatform.type == .browser {
                
                // If browser mic is still active, ignore window close (tab switch)
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
    
    // MARK: - State Management (simplified - no queue dispatching needed)
    private func updateMeetingState() {
        // Already on stateQueue
        let wasInMeeting = isInMeeting
        let activeMeetings = meetingStates.values.filter { $0.isActive }
        isInMeeting = !activeMeetings.isEmpty
        
        // Debug log all current states
        logger.debug("Current meeting states:")
        for (_, state) in meetingStates {
            let browserInfo = state.hostBrowser != nil ? state.hostBrowser!.name : "N/A"
            logger.debug("  - \(state.platform.name): window=\(state.hasWindow), mic=\(state.hasMicrophone), browser=\(browserInfo), active=\(state.isActive)")
        }
        
        // Log current state
        if !activeMeetings.isEmpty {
            let platforms = activeMeetings.map { $0.platform.name }.joined(separator: ", ")
            logger.info("✅ Active meetings: \(platforms)")
        }
        
        // Detect state changes
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
        
        let platformInfos = platforms.map { platform in
            MeetingStartedEvent.PlatformInfo(id: platform.id, name: platform.name)
        }
        let event = MeetingStartedEvent(platforms: platformInfos)
        
        // Send to result stream (this may need to be on main queue)
        DispatchQueue.main.async {
            self.resultStream.sendEvent(event.toDictionary())
        }
    }
    
    private func handleMeetingEnd() {
        logger.info("🔴 Meeting ENDED")
        
        let event = MeetingEndedEvent()
        
        // Send to result stream (this may need to be on main queue)
        DispatchQueue.main.async {
            self.resultStream.sendEvent(event.toDictionary())
        }
    }
    
//    private func updatePlatformWindows(windows: Set<WindowInfo>, isAdding: Bool) {
//        for window in windows {
//            guard let platform = window.platform else { continue }
//            
//            // Skip browsers - they're not meeting platforms
//            if platform.type == .browser {
//                continue
//            }
//            
//            if isAdding {
//                // Adding window
//                var hostBrowser: SupportedPlatform? = nil
//                
//                // For web apps, determine which browser is hosting
//                if platform.type == .web, let windowBundleID = window.bundleIdentifier {
//                    hostBrowser = SupportedPlatform.from(bundleID: windowBundleID)
//                }
//                
//                if var state = meetingStates[platform.id] {
//                    // Update existing state
//                    state = MeetingState(
//                        platform: platform,
//                        hasWindow: true,
//                        hasMicrophone: state.hasMicrophone,  // Preserve existing
//                        hasCamera: state.hasCamera,           // Preserve existing
//                        startTime: state.startTime,
//                        hostBrowser: hostBrowser
//                    )
//                    meetingStates[platform.id] = state
//                } else {
//                    // Create new state
//                    // For web apps, check if the browser already has mic access
//                    let hasMic = platform.type == .web && hostBrowser != nil &&
//                                activeBrowserMicrophones.contains(hostBrowser!)
//                    
//                    meetingStates[platform.id] = MeetingState(
//                        platform: platform,
//                        hasWindow: true,
//                        hasMicrophone: hasMic,  // For web: check browser, for desktop: false
//                        hasCamera: false,
//                        startTime: Date(),
//                        hostBrowser: hostBrowser
//                    )
//                }
//                logger.debug("Window detected for \(platform.name)")
//            } else {
//                // Removing window - keep as is
//                if var state = meetingStates[platform.id] {
//                    state = MeetingState(
//                        platform: platform,
//                        hasWindow: false,
//                        hasMicrophone: state.hasMicrophone,  // Preserve
//                        hasCamera: state.hasCamera,           // Preserve
//                        startTime: state.startTime,
//                        hostBrowser: state.hostBrowser
//                    )
//                    meetingStates[platform.id] = state
//                    logger.debug("Window removed for \(platform.name)")
//                }
//            }
//        }
//        
//        // Clean up states
//        meetingStates = meetingStates.filter { _, state in
//            state.hasWindow || state.hasMicrophone || state.hasCamera
//        }
//        
//        updateMeetingState()
//    }
    
//    private func updatePlatformWindows(windows: Set<WindowInfo>, isAdding: Bool) {
//        // Already on stateQueue, simplified implementation
//        for window in windows {
//            guard let platform = window.platform else { continue }
//            
//            // Skip browsers - they're not meeting platforms
//            if platform.type == .browser {
//                continue
//            }
//            
//            if isAdding {
//                // Adding window
//                var hostBrowser: SupportedPlatform? = nil
//                var hasMic: Bool = false
//                
//                // For web apps, determine which browser is hosting
//                if platform.type == .web, let windowBundleID = window.bundleIdentifier {
//                    hostBrowser = SupportedPlatform.from(bundleID: windowBundleID)
//                    // Check if the browser has microphone access
//                    hasMic = hostBrowser != nil && activeBrowserMicrophones.contains(hostBrowser!)
//                }
//                
//                // Check if the browser has microphone access
////                let hasMic = hostBrowser != nil && activeBrowserMicrophones.contains(hostBrowser!)
//                
//                if var state = meetingStates[platform.id] {
//                    
//                    // Update existing state
//                    // For desktop apps, preserve existing mic state
//                    // For web apps, use the calculated browser mic state
//                    let micState = platform.type == .desktop ? state.hasMicrophone : hasMic
//                    // Update existing state
//                    state = MeetingState(
//                        platform: platform,
//                        hasWindow: true,
//                        hasMicrophone: micState,
//                        hasCamera: state.hasCamera,
//                        startTime: state.startTime,
//                        hostBrowser: hostBrowser
//                    )
//                    meetingStates[platform.id] = state
//                } else {
//                    // Create new state
//                    meetingStates[platform.id] = MeetingState(
//                        platform: platform,
//                        hasWindow: true,
//                        hasMicrophone: hasMic,
//                        hasCamera: false,
//                        startTime: Date(),
//                        hostBrowser: hostBrowser
//                    )
//                }
//                logger.debug("Window detected for \(platform.name)")
//            } else {
//                // Removing window
//                if var state = meetingStates[platform.id] {
//                    state = MeetingState(
//                        platform: platform,
//                        hasWindow: false,
//                        hasMicrophone: state.hasWindow, // No window = no mic for web apps
//                        hasCamera: state.hasCamera,
//                        startTime: state.startTime,
//                        hostBrowser: nil
//                    )
//                    meetingStates[platform.id] = state
//                    logger.debug("Window removed for \(platform.name)")
//                }
//            }
//        }
//        
//        // Clean up states that have no window and no mic
//        meetingStates = meetingStates.filter { _, state in
//            state.hasWindow || state.hasMicrophone || state.hasCamera
//        }
//        
//        updateMeetingState()
//    }
    
//    private func updatePlatformMicrophone(platforms: Set<SupportedPlatform>) {
//        // Already on stateQueue, simplified implementation
//        
//        // Separate browsers from actual meeting platforms
//        let browsers = platforms.filter { $0.type == .browser }
//        let meetingPlatforms = platforms.filter { $0.type != .browser }
//        
//        // Update active browser list
//        activeBrowserMicrophones = browsers
//        
//        // Update desktop meeting platforms that have direct mic access
//        for platform in meetingPlatforms {
//            if var state = meetingStates[platform.id] {
//                state = MeetingState(
//                    platform: platform,
//                    hasWindow: state.hasWindow,
//                    hasMicrophone: true,
//                    hasCamera: state.hasCamera,
//                    startTime: state.startTime,
//                    hostBrowser: state.hostBrowser
//                )
//                meetingStates[platform.id] = state
//            } else {
//                // Desktop app with mic but no window yet
//                meetingStates[platform.id] = MeetingState(
//                    platform: platform,
//                    hasWindow: false,
//                    hasMicrophone: true,
//                    hasCamera: false,
//                    startTime: Date(),
//                    hostBrowser: nil
//                )
//            }
//        }
//        
//        // Remove mic from desktop platforms that no longer have it
//        for (platformId, state) in meetingStates {
//            if state.platform.type == .desktop && !meetingPlatforms.contains(where: { $0.id == platformId }) {
//                meetingStates[platformId] = MeetingState(
//                    platform: state.platform,
//                    hasWindow: state.hasWindow,
//                    hasMicrophone: false,
//                    hasCamera: state.hasCamera,
//                    startTime: state.startTime,
//                    hostBrowser: state.hostBrowser
//                )
//            }
//        }
//        
//        // Update web meeting platforms based on their host browser's mic status
//        for (platformId, state) in meetingStates {
//            if state.platform.type == .web && state.hasWindow {
//                let hasBrowserMic = state.hostBrowser != nil && browsers.contains(state.hostBrowser!)
//                
//                meetingStates[platformId] = MeetingState(
//                    platform: state.platform,
//                    hasWindow: state.hasWindow,
//                    hasMicrophone: hasBrowserMic,
//                    hasCamera: state.hasCamera,
//                    startTime: state.startTime,
//                    hostBrowser: state.hostBrowser
//                )
//            }
//        }
//        
//        // Clean up states
//        meetingStates = meetingStates.filter { _, state in
//            state.hasWindow || state.hasMicrophone || state.hasCamera
//        }
//        
//        updateMeetingState()
//    }
    
    
    private func updatePlatformCamera(platforms: Set<SupportedPlatform>) {
        // Already on stateQueue, simplified implementation
        
        let browsers = platforms.filter { $0.type == .browser }
        let meetingPlatforms = platforms.filter { $0.type != .browser }
        
        // Update desktop platforms with direct camera access
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
}

extension AutopilotService {
    /// Clean up stale web meeting states that claim to have windows but don't actually exist
    private func cleanupStaleWebMeetingStates() {
        // Get current actual meeting windows from the window monitor
        let currentWindows = windowMonitor.activeMeetingWindows
        
        // Create a set of valid state keys based on current windows
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
        
        // Remove web meeting states that claim to have windows but aren't in current windows
        var staleMeetingStates: [String] = []
        
        for (stateKey, state) in meetingStates {
            if state.platform.type == .web && state.hasWindow {
                if !validWebStateKeys.contains(stateKey) {
                    staleMeetingStates.append(stateKey)
                    logger.info("Removing stale web meeting state: \(state.platform.name) in \(state.hostBrowser?.name ?? "unknown browser")")
                }
            }
        }
        
        // Remove stale states
        for staleKey in staleMeetingStates {
            meetingStates.removeValue(forKey: staleKey)
        }
    }
    
    /// Get detailed meeting state for a specific platform and browser combination
    func meetingState(for platformId: String, hostBrowser: SupportedPlatform? = nil) -> MeetingState? {
        stateQueue.sync {
            let platform = SupportedPlatform.platform(for: PlatformID(rawValue: platformId) ?? .googleMeet)
            guard let platform = platform else { return nil }
            
            let key = createStateKey(platform: platform, hostBrowser: hostBrowser)
            return meetingStates[key]
        }
    }
    
    /// Get all meeting states for a specific platform across all browsers
    func meetingStates(for platformId: String) -> [MeetingState] {
        stateQueue.sync {
            return meetingStates.values.filter { $0.platform.id == platformId }
        }
    }
    
    private func createStateKey(platform: SupportedPlatform, hostBrowser: SupportedPlatform?) -> String {
        if platform.type == .web, let browser = hostBrowser {
            // For web platforms, include the browser in the key to distinguish instances
            return "\(platform.id)@\(browser.id)"
        } else {
            // For desktop apps, use platform ID directly
            return platform.id
        }
    }

    private func updatePlatformWindows(windows: Set<WindowInfo>, isAdding: Bool) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            
            for window in windows {
                guard let platform = window.platform else { continue }
                
                // Skip browsers - they're not meeting platforms
                if platform.type == .browser {
                    continue
                }
                
                if isAdding {
                    // Adding window
                    var hostBrowser: SupportedPlatform? = nil
                    
                    // For web apps, determine which browser is hosting
                    if platform.type == .web, let windowBundleID = window.bundleIdentifier {
                        hostBrowser = SupportedPlatform.from(bundleID: windowBundleID)
                    }
                    
                    // Create unique state key
                    let stateKey = self.createStateKey(platform: platform, hostBrowser: hostBrowser)
                    
                    // Check if the browser has microphone access (for web platforms)
                    let hasMic = self.getPlatformMicrophoneState(platform: platform, hostBrowser: hostBrowser)
                    
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
                    // Removing window - need to find and update the correct state
                    self.removeWindowFromStates(platform: platform, window: window)
                }
            }
            
            // Clean up states that have no window and no mic and no camera
            self.meetingStates = self.meetingStates.filter { _, state in
                state.hasWindow || state.hasMicrophone || state.hasCamera
            }
            
            self.updateMeetingState()
        }
    }

    private func removeWindowFromStates(platform: SupportedPlatform, window: WindowInfo) {
        // For web platforms, we need to find the specific browser-platform combination
        if platform.type == .web, let windowBundleID = window.bundleIdentifier,
           let hostBrowser = SupportedPlatform.from(bundleID: windowBundleID) {
            
            let stateKey = createStateKey(platform: platform, hostBrowser: hostBrowser)
            
            if var state = meetingStates[stateKey] {
                // Remove window but keep other state if browser still has microphone
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
            // Desktop platform - simpler case
            let stateKey = createStateKey(platform: platform, hostBrowser: nil)
            
            if var state = meetingStates[stateKey] {
                state = MeetingState(
                    platform: platform,
                    hasWindow: false,
                    hasMicrophone: false, // Desktop apps without windows typically don't have active mics
                    hasCamera: false,
                    startTime: state.startTime,
                    hostBrowser: nil
                )
                meetingStates[stateKey] = state
                logger.debug("Window removed for \(platform.name)")
            }
        }
    }

    private func getPlatformMicrophoneState(platform: SupportedPlatform, hostBrowser: SupportedPlatform?) -> Bool {
        switch platform.type {
        case .desktop:
            // For desktop platforms, check if the platform itself has microphone access
            return activeBrowserMicrophones.contains(platform)
        case .web:
            // For web platforms, check if the hosting browser has microphone access
            return hostBrowser != nil && activeBrowserMicrophones.contains(hostBrowser!)
        case .browser:
            // Browsers themselves are never meeting platforms
            return false
        }
    }

    private func updatePlatformMicrophone(platforms: Set<SupportedPlatform>) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Separate browsers from actual meeting platforms
            let browsers = platforms.filter { $0.type == .browser }
            let meetingPlatforms = platforms.filter { $0.type != .browser }
            
            // Update active browser list
            self.activeBrowserMicrophones = browsers
            
            // Log current browser microphone state
            if !browsers.isEmpty {
                let browserNames = browsers.map { $0.name }.joined(separator: ", ")
                self.logger.debug("Browsers with microphone access: \(browserNames)")
            } else {
                self.logger.debug("No browsers have microphone access")
            }
            
            // Update all meeting states based on new microphone information
            var updatedStates: [String: MeetingState] = [:]
            
            for (stateKey, state) in self.meetingStates {
                let updatedState: MeetingState
                
                if state.platform.type == .desktop {
                    // Desktop platform: check if it has direct microphone access
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
                    // Web platform: check if hosting browser has microphone access
                    // CRITICAL FIX: Only clear hostBrowser if window is also gone
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
                    // Browser type - shouldn't happen as meeting platforms, but handle gracefully
                    updatedState = state
                }
                
                updatedStates[stateKey] = updatedState
            }
            
            // Also create states for desktop platforms that have microphone but no existing state
            for platform in meetingPlatforms {
                let stateKey = self.createStateKey(platform: platform, hostBrowser: nil)
                
                if updatedStates[stateKey] == nil {
                    // New desktop app with microphone access but no window yet
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
            
            // Clean up states that have no activity
            // For web platforms: if browser has no mic and state claims to have window,
            // verify the window actually exists by checking current windows
            self.cleanupStaleWebMeetingStates()
            
            // Clean up states that have no activity
            self.meetingStates = self.meetingStates.filter { _, state in
                state.hasWindow || state.hasMicrophone || state.hasCamera
            }
            
            self.updateMeetingState()
        }
    }

}


// MARK: - Public API Extensions
extension AutopilotService {
    /// Current meeting status
    var isMeetingActive: Bool {
        stateQueue.sync { isInMeeting }
    }
    
    /// Get all active meeting platforms
    var activeMeetingPlatforms: [SupportedPlatform] {
        stateQueue.sync {
            meetingStates.values
                .filter { $0.isActive }
                .map { $0.platform }
        }
    }
    
    /// Get detailed meeting state for a specific platform
    func meetingState(for platformId: String) -> MeetingState? {
        stateQueue.sync { meetingStates[platformId] }
    }
    
    /// Get all current meeting states (for debugging)
    var allMeetingStates: [String: MeetingState] {
        stateQueue.sync { meetingStates }
    }
}
