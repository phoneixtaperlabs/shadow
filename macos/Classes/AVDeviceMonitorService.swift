import Foundation
import OSLog
import Combine

// MARK: - Models
struct Attribution {
    enum AttributionType: String {
        case microphone = "mic"
        case camera = "cam"
    }
    
    let type: AttributionType
    let bundleIdentifier: String
    
    init?(from string: String) {
        // Parse "mic:com.google.Chrome" or "cam:com.google.Chrome"
        let components = string.split(separator: ":", maxSplits: 1)
        guard components.count == 2,
              let type = AttributionType(rawValue: String(components[0])) else {
            return nil
        }
        
        self.type = type
        self.bundleIdentifier = String(components[1])
    }
}

// MARK: - Protocols
protocol AVMonitoring {
    func startMonitoring()
    func stopMonitoring()
}


// MARK: - AVDeviceMonitorService
final class AVDeviceMonitorService: AVMonitoring {
    static let shared = AVDeviceMonitorService()
    
    // MARK: - Publishers
    @Published private(set) var activeMicrophonePlatforms: Set<SupportedPlatform> = []
    @Published private(set) var activeCameraPlatforms: Set<SupportedPlatform> = []
    
    // Device event publishers
    private let deviceEventSubject = PassthroughSubject<AVDeviceEvent, Never>()
    var deviceEventPublisher: AnyPublisher<AVDeviceEvent, Never> {
        deviceEventSubject.eraseToAnyPublisher()
    }
    
    // Error publisher
    private let errorSubject = PassthroughSubject<MonitoringError, Never>()
    var errorPublisher: AnyPublisher<MonitoringError, Never> {
        errorSubject.eraseToAnyPublisher()
    }
    
    // Combined state publishers
    var microphonePublisher: AnyPublisher<Set<SupportedPlatform>, Never> {
        $activeMicrophonePlatforms.eraseToAnyPublisher()
    }
    
    var cameraPublisher: AnyPublisher<Set<SupportedPlatform>, Never> {
        $activeCameraPlatforms.eraseToAnyPublisher()
    }
    
    // MARK: - Properties
    private var logProcess: Process?
    private var pipe: Pipe?
    private var errorPipe: Pipe?
    private let logger = Logger(subsystem: "com.yourapp.avmonitor", category: "AVMonitor")
    private let stateQueue = DispatchQueue(label: "com.yourapp.avmonitor.stateQueue")
    private var cancellables = Set<AnyCancellable>()
    private init() {}
    
    
    // MARK: - Convenience Methods
    
    /// Returns whether any platform is currently using the microphone
    var isMicrophoneInUse: Bool {
        return !activeMicrophonePlatforms.isEmpty
    }
    
    /// Returns whether any platform is currently using the camera
    var isCameraInUse: Bool {
        return !activeCameraPlatforms.isEmpty
    }
    
    /// Returns the primary platform using the microphone (if multiple, returns based on priority)
    var primaryMicrophonePlatform: SupportedPlatform? {
        // Prioritize desktop apps over browsers
        return activeMicrophonePlatforms.first { $0.type == .desktop } ??
        activeMicrophonePlatforms.first { $0.type == .web } ??
        activeMicrophonePlatforms.first
    }
    
    func startMonitoring() {
        guard logProcess == nil else {
            logger.warning("Monitoring is already active")
            AutopilotLogger.shared.warning("[AVDevice] Monitoring is already active")
            return
        }
        
        guard isLogExecutableAvailable() else {
            errorSubject.send(.logExecutableUnavailable)
            return
        }
        
        logger.info("Starting log stream monitoring")
        
        self.pipe = Pipe()
        self.errorPipe = Pipe()
        
        let process = createLogProcess()
        self.logProcess = process
        
        setupStandardOutput(for: process)
        setupStandardError(for: process)
        setupTerminationHandler(for: process)
        
        run(process)
    }
    
    private func isLogExecutableAvailable() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/log") else {
            logger.error("/usr/bin/log not found – Unified Logging unavailable")
            AutopilotLogger.shared.error("/usr/bin/log not found – Unified Logging unavailable")
            return false
        }
        return true
    }
    
    private func createLogProcess() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--predicate",
            "subsystem == 'com.apple.controlcenter' AND eventMessage CONTAINS 'Active activity attributions changed to'"
        ]
        return process
    }
    
    private func setupStandardOutput(for process: Process) {
        process.standardOutput = pipe
        pipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            
            output.enumerateLines { line, _ in
                self?.processLogLine(line)
            }
        }
    }
    
    private func setupStandardError(for process: Process) {
        process.standardError = errorPipe
        errorPipe?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            AutopilotLogger.shared.error("STDERR -- \(output)")
            self.logger.error("STDERR -- \(output)")
        }
    }
    
    private func setupTerminationHandler(for process: Process) {
        process.terminationHandler = { [weak self] process in
            self?.logger.info("Log process terminated with status: \(process.terminationStatus)")
            self?.handleProcessTermination()
        }
    }
    
    private func run(_ process: Process) {
        do {
            try process.run()
            logger.info("Log stream process started successfully")
        } catch {
            AutopilotLogger.shared.error("Failed to start LS--p \(error.localizedDescription)")
            logger.error("Failed to start log stream process: \(error)")
            errorSubject.send(.logProcessFailedToStart(error))
            handleProcessTermination()
        }
    }
    
    func stopMonitoring() {
        logger.info("Stopping log stream monitoring")
        
        pipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        
        self.pipe = nil
        self.errorPipe = nil
        
        if let process = logProcess {
            if process.isRunning {
                process.terminate()
            }
            logProcess = nil
        }
        
        stateQueue.async {
            self.activeMicrophonePlatforms.removeAll()
            self.activeCameraPlatforms.removeAll()
        }
    }
    
    // MARK: - Private Methods
    private func processLogLine(_ line: String) {
        print("line -- \(line)")
        guard line.contains("Active activity attributions changed to") else { return }
        
        logger.debug("Processing log line: \(line)")
        
        guard let attributions = extractAttributions(from: line) else {
            logger.warning("Failed to extract attributions from line: \(line)")
            return
        }
        
        stateQueue.async {
            self.processAttributions(attributions)
        }
    }
    
    private func extractAttributions(from line: String) -> [String]? {
        guard let range = line.range(of: "Active activity attributions changed to ", options: .backwards) else {
            return nil
        }
        
        let attributionsPart = String(line[range.upperBound...])
        let trimmed = attributionsPart.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed == "[]" {
            return []
        }
        
        guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else {
            return nil
        }
        
        let content = trimmed.dropFirst().dropLast()
        
        let elements = content.split(separator: ",").compactMap { element -> String? in
            let cleaned = element
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            
            return cleaned.isEmpty ? nil : cleaned
        }
        
        return elements
    }
    
    private func processAttributions(_ attributionStrings: [String]) {
        // Parse attributions into platforms
        var microphonePlatforms: Set<SupportedPlatform> = []
        var cameraPlatforms: Set<SupportedPlatform> = []
        
        for attribution in attributionStrings {
            // Check if it's a microphone attribution
            if attribution.hasPrefix("mic:") {
                if let platform = SupportedPlatform.from(microphoneUsageString: attribution) {
                    microphonePlatforms.insert(platform)
                    logger.debug("Detected microphone usage by: \(platform.name) (\(platform.id))")
                } else {
                    logger.warning("Unknown microphone attribution: \(attribution)")
                }
            }
            // Check if it's a camera attribution
            else if attribution.hasPrefix("cam:") {
                // Extract bundle ID from camera attribution
                let cameraAttribution = attribution.replacingOccurrences(of: "cam:", with: "mic:")
                if let platform = SupportedPlatform.from(microphoneUsageString: cameraAttribution) {
                    cameraPlatforms.insert(platform)
                    logger.debug("Detected camera usage by: \(platform.name) (\(platform.id))")
                } else {
                    logger.warning("Unknown camera attribution: \(attribution)")
                }
            }
        }
        
        // Check for microphone changes
        if microphonePlatforms != activeMicrophonePlatforms {
            handleMicrophoneChange(from: activeMicrophonePlatforms, to: microphonePlatforms)
            activeMicrophonePlatforms = microphonePlatforms
        }
        
        // Check for camera changes
//        if cameraPlatforms != activeCameraPlatforms {
//            handleCameraChange(from: activeCameraPlatforms, to: cameraPlatforms)
//            activeCameraPlatforms = cameraPlatforms
//        }
    }
    
    private func handleMicrophoneChange(from oldPlatforms: Set<SupportedPlatform>, to newPlatforms: Set<SupportedPlatform>) {
        let added = newPlatforms.subtracting(oldPlatforms)
        let removed = oldPlatforms.subtracting(newPlatforms)
        
        if !added.isEmpty {
            logger.info("Microphone started by: \(added.map { $0.name }.joined(separator: ", "))")
        }
        
        if !removed.isEmpty {
            logger.info("Microphone stopped by: \(removed.map { $0.name }.joined(separator: ", "))")
        }
        
        // Emit event (replacing delegate call)
        deviceEventSubject.send(.microphoneChanged(newPlatforms))
    }

    private func handleCameraChange(from oldPlatforms: Set<SupportedPlatform>, to newPlatforms: Set<SupportedPlatform>) {
        let added = newPlatforms.subtracting(oldPlatforms)
        let removed = oldPlatforms.subtracting(newPlatforms)
        
        if !added.isEmpty {
            logger.info("Camera started by: \(added.map { $0.name }.joined(separator: ", "))")
        }
        
        if !removed.isEmpty {
            logger.info("Camera stopped by: \(removed.map { $0.name }.joined(separator: ", "))")
        }
        
        // Emit event (replacing delegate call)
        deviceEventSubject.send(.cameraChanged(newPlatforms))
    }
    
    private func handleProcessTermination() {
        AutopilotLogger.shared.warning("LP terminated unexpectedly")
        logger.warning("Log process terminated unexpectedly")
        errorSubject.send(.logProcessTerminatedUnexpectedly)
        
        pipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        self.pipe = nil
        self.errorPipe = nil
        logProcess = nil
        
        stateQueue.async { [weak self] in
            self?.activeMicrophonePlatforms.removeAll()
            self?.activeCameraPlatforms.removeAll()
        }
    }
}




