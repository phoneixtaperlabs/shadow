import Foundation
import os.log

// MARK: - AutopilotLogger Class
final class AutopilotLogger {
    // MARK: - Singleton
    private static var _shared: AutopilotLogger?
    private static let configurationLock = NSLock()
    
    static var shared: AutopilotLogger {
        guard let logger = _shared else {
            fatalError("AutopilotLogger.configure() must be called before accessing AutopilotLogger.shared")
        }
        return logger
    }
    
    // MARK: - Configuration
    static func configure(subsystem: String,
                          category: String,
                          logDirectory: URL? = nil,
                          retentionDays: Int = 30,
                          minimumLogLevel: LogType = .debug) {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        
        if _shared == nil {
            _shared = AutopilotLogger(subsystem: subsystem,
                                   category: category,
                                   logDirectory: logDirectory,
                                   retentionDays: retentionDays,
                                   minimumLogLevel: minimumLogLevel)
        } else {
            print("Warning: AutopilotLogger already configured. Configuration can only be set once at startup.")
        }
    }
    
    // MARK: - Properties
    private let osLog: OSLog
    private let logDirectory: URL
    private var currentLogFileURL: URL?
    private var logFileHandle: FileHandle?
    private let dateFormatter: DateFormatter
    private let timestampFormatter: DateFormatter
    private let logQueue = DispatchQueue(label: "com.shadow.autopilot_plugin.logging", qos: .utility)
    private let retentionDays: Int
    private let fileLock = NSLock()
    
    // Current date tracking for rotation
    private var currentLogDate: String = ""
    
    // Log level configuration
    var minimumLogLevel: LogType {
        didSet {
            info("Minimum log level changed to: \(minimumLogLevel.rawValue)")
        }
    }
    
    // Log levels
    enum LogType: String, Comparable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
        
        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            }
        }
        
        static func < (lhs: LogType, rhs: LogType) -> Bool {
            let order: [LogType] = [.debug, .info, .warning, .error]
            guard let lhsIndex = order.firstIndex(of: lhs),
                  let rhsIndex = order.firstIndex(of: rhs) else {
                return false
            }
            return lhsIndex < rhsIndex
        }
    }
    
    // MARK: - Initialization
    private init(subsystem: String,
                 category: String,
                 logDirectory: URL? = nil,
                 retentionDays: Int = 7,
                 minimumLogLevel: LogType = .debug) {
        
        // Initialize OSLog
        self.osLog = OSLog(subsystem: subsystem, category: category)
        
        // Set log level
        self.minimumLogLevel = minimumLogLevel
        
        // Set retention period
        self.retentionDays = retentionDays
        
        // Initialize date formatters
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd"
        self.dateFormatter.timeZone = TimeZone.current
        
        self.timestampFormatter = DateFormatter()
        self.timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.timestampFormatter.timeZone = TimeZone.current
        
        // Setup log directory
        let fileManager = FileManager.default
        if let customLogDirectory = logDirectory {
            self.logDirectory = customLogDirectory
        } else {
            self.logDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("com.taperlabs.shadow", isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
        }
        
        // Create logs directory if it doesn't exist
        do {
            try fileManager.createDirectory(at: self.logDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create log directory: \(error)")
        }
        
        // Initialize with current date
        self.currentLogDate = self.dateFormatter.string(from: Date())
        
        // Setup current log file
        self.setupLogFile()
        
        // Clean up old files on startup
        self.cleanupOldLogFiles()
        
        // Log initialization
        self.log(message: "AutopilotLogger initialized with subsystem: \(subsystem), category: \(category), minimumLogLevel: \(minimumLogLevel.rawValue), retentionDays: \(retentionDays)",
                 type: .info, file: #file, function: #function, line: #line)
    }
    
    deinit {
        // Clean up resources
        fileLock.lock()
        defer { fileLock.unlock() }
        
        try? self.logFileHandle?.close()
        self.logFileHandle = nil
        
        // Log deinitialization (this might not write due to closed handle)
        os_log("AutopilotLogger deinitialized", log: self.osLog, type: .info)
    }
    
    // MARK: - Public Methods
    
    /// Force manual log rotation (useful for testing or manual rotation)
    func forceRotateLogFile() {
        logQueue.async { [weak self] in
            self?.rotateLogFileIfNeeded(force: true)
        }
    }
    
    /// Log a message with a specific log level and source location information
    func log(message: String,
             type: LogType,
             file: String = #file,
             function: String = #function,
             line: Int = #line) {
        
        // Skip logging if below minimum log level
        guard type >= minimumLogLevel else {
            return
        }
        
        // Log to OSLog
        os_log("%{public}@", log: self.osLog, type: type.osLogType, message)
        
        // Write to file asynchronously
        logQueue.async { [weak self] in
            self?.writeToFile(message: message, type: type, file: file, function: function, line: line)
        }
    }
    
    /// Convenience methods for different log levels with source location
    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message: message, type: .debug, file: file, function: function, line: line)
    }
    
    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message: message, type: .info, file: file, function: function, line: line)
    }
    
    func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message: message, type: .warning, file: file, function: function, line: line)
    }
    
    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message: message, type: .error, file: file, function: function, line: line)
    }
    
    // MARK: - Private Methods
    
    private func writeToFile(message: String, type: LogType, file: String, function: String, line: Int) {
        // Check if we need to rotate first (this handles day changes)
        rotateLogFileIfNeeded()
        
        guard let logFileHandle = self.logFileHandle else {
            print("Log file handle is nil, attempting to recreate")
            setupLogFile()
            guard let logFileHandle = self.logFileHandle else {
                print("Failed to recreate log file handle")
                return
            }
            return
        }
        
        // Extract filename from path
        let filename = URL(fileURLWithPath: file).lastPathComponent
        
        // Format log entry
        let utcTimestamp = ISO8601DateFormatter().string(from: Date())
        let localTimestamp = timestampFormatter.string(from: Date())
        let threadID = Thread.current.hashValue
        
        let logEntry = "[UTC: \(utcTimestamp)] [LOCAL: \(localTimestamp)] [\(type.rawValue)] [Thread: \(threadID)] [\(function)] \(message)\n"
        
        // Write to file with proper error handling
        guard let data = logEntry.data(using: .utf8) else {
            print("Failed to encode log entry to UTF-8")
            return
        }
        
        fileLock.lock()
        defer { fileLock.unlock() }
        
        do {
            try logFileHandle.write(contentsOf: data)
            try logFileHandle.synchronize()
        } catch {
            print("Failed to write to log file: \(error)")
            // Attempt to recreate file handle
            setupLogFile()
        }
    }
    
    private func setupLogFile() {
        fileLock.lock()
        defer { fileLock.unlock() }
        
        // Close existing handle
        try? logFileHandle?.close()
        logFileHandle = nil
        
        // Create log file URL for current date
        let logFileName = "\(currentLogDate)-autopilot.log"
        currentLogFileURL = logDirectory.appendingPathComponent(logFileName)
        
        guard let logFileURL = currentLogFileURL else {
            print("Failed to create log file URL")
            return
        }
        
        let fileManager = FileManager.default
        
        // Create log file if it doesn't exist
        let fileExists = fileManager.fileExists(atPath: logFileURL.path)
        if !fileExists {
            let success = fileManager.createFile(atPath: logFileURL.path, contents: nil, attributes: nil)
            if !success {
                print("Failed to create log file at path: \(logFileURL.path)")
                return
            }
        }
        
        // Open file handle for writing
        do {
            logFileHandle = try FileHandle(forWritingTo: logFileURL)
            logFileHandle?.seekToEndOfFile()
            
            // Write header if this is a new file
            if !fileExists || logFileHandle?.offsetInFile == 0 {
                let header = "--- Autopilot Plugin Log File: \(currentLogDate) ---\n"
                if let headerData = header.data(using: .utf8) {
                    try logFileHandle?.write(contentsOf: headerData)
                }
            }
        } catch {
            print("Failed to open log file: \(error)")
            logFileHandle = nil
        }
    }
    
    private func rotateLogFileIfNeeded(force: Bool = false) {
        let today = dateFormatter.string(from: Date())
        
        // Check if we need to rotate (new day or force)
        if today != currentLogDate || force {
            let previousDate = currentLogDate
            currentLogDate = today
            
            print("Rotating log file from \(previousDate) to \(today)")
            
            // Setup new log file
            setupLogFile()
            
            // Clean up old files
            cleanupOldLogFiles()
        }
    }
    
    private func cleanupOldLogFiles() {
        let fileManager = FileManager.default
        
        do {
            let files = try fileManager.contentsOfDirectory(at: logDirectory,
                                                          includingPropertiesForKeys: [.creationDateKey],
                                                          options: [])
            
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!
            
            for fileURL in files where fileURL.pathExtension == "log" {
                do {
                    let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                    if let creationDate = attributes[.creationDate] as? Date, creationDate < cutoffDate {
                        try fileManager.removeItem(at: fileURL)
                        print("Deleted old log file: \(fileURL.lastPathComponent)")
                    }
                } catch {
                    print("Failed to process log file \(fileURL.lastPathComponent): \(error)")
                }
            }
        } catch {
            print("Failed to cleanup old log files: \(error)")
        }
    }
}
