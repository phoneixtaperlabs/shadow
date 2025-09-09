import Foundation

enum WindowEvent: Equatable {
    case windowsDetected(Set<WindowInfo>)
    case windowsEnded(Set<WindowInfo>)
}

enum AVDeviceEvent: Equatable {
    case microphoneChanged(Set<SupportedPlatform>)
    case cameraChanged(Set<SupportedPlatform>)
}
