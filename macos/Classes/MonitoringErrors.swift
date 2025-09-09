import  Foundation

/// Defines specific errors that can be thrown by the monitoring services.
enum MonitoringError: Error, LocalizedError {
    case logProcessFailedToStart(Error)
    case logProcessTerminatedUnexpectedly
    case logExecutableUnavailable
    case cannotFetchWindowList
    case invalidConfiguration(String)
    
    var errorDescription: String? {
        switch self {
        case .logProcessFailedToStart(let underlyingError):
            return "The log streaming process could not be started. Underlying error: \(underlyingError.localizedDescription)"
        case .logProcessTerminatedUnexpectedly:
            return "The log streaming process terminated unexpectedly."
        case .logExecutableUnavailable:
            return "The '/usr/bin/log' command is not available on this system."
        case .cannotFetchWindowList:
            return "Failed to get the window list from the operating system."
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        }
    }
}
