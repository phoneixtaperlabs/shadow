import Foundation

// MARK: - Platform Type
enum PlatformType {
    case desktop
    case web
    case browser
}

// MARK: - Platform Identifiers
// This enum provides type-safe access to platform IDs
enum PlatformID: String {
    // Desktop Apps
    case microsoftTeams = "microsoftTeams"
    case ciscoWebex = "ciscoWebex"
    case goTo = "goTo"
    case zoom = "zoom"
    case slack = "slack"
    case discord = "discord"
    
    //NEw Desktop App
    case lark = "lark"
    
    // Web Apps
    case googleMeet = "googleMeet"
    
    // Browsers
    case googleChrome = "googleChrome"
    case safari = "appleSafari"
    case edge = "microsoftEdge"
    case firefox = "mozillaFirefox"
    
    // New Browsers
    case comet = "comet"
    case brave = "brave"
    case zen = "zen"
    case dia = "dia"
    case atlas = "atlas"
    
    case arc = "arc"
    
    //PWA
    case googleMeetPWA = "googleMeetPWA"
}

// MARK: - Bundle Identifiers
// Centralized bundle ID constants
enum BundleID {
    // Desktop Apps
    static let teams = "com.microsoft.teams2"
    static let webex = "Cisco-Systems.Spark"
    static let goTo = "com.logmein.goto"
    static let zoom = "us.zoom.xos"
    static let slack = "com.tinyspeck.slackmacgap"
    static let discord = "com.hnc.Discord"
    
    // NEW Desktop App
    static let lark = "com.larksuite.larkApp"
    
    // Browsers
    static let chrome = "com.google.Chrome"
    
    // Changed from com.apple.WebKit.GPU to match microphone attribution logs
    static let safari = "com.apple.Safari"
    static let edge = "com.microsoft.edgemac"
    static let firefox = "org.mozilla.firefox"
    
    // New Browsers
    static let comet = "ai.perplexity.comet"
    static let brave = "com.brave.Browser"
    static let zen = "app.zen-browser.zen"
    static let dia = "company.thebrowser.dia"
    static let atlas = "com.openai.atlas"
    
    //Arc 재지원
    static let arc = "company.thebrowser.Browser"
    
    static let chromeGoogleMeetPWA = "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
}

// MARK: - SupportedPlatform
struct SupportedPlatform: Hashable, Identifiable {
    let id: String
    let name: String
    let type: PlatformType
    
    // For .web type
    let windowTitleKeywords: [String]?
    let compatibleBrowserIDs: [PlatformID]? // e.g. [.googleChrome, .safari]
    
    // For .desktop and .browser type
    let microphoneBundleIDs: [String]?
    
    init(id: String, name: String, type: PlatformType,
         windowTitleKeywords: [String]? = nil,
         compatibleBrowserIDs: [PlatformID]? = nil,
         microphoneBundleIDs: [String]? = nil)
    {
        self.id = id
        self.name = name
        self.type = type
        self.windowTitleKeywords = windowTitleKeywords
        self.compatibleBrowserIDs = compatibleBrowserIDs
        self.microphoneBundleIDs = microphoneBundleIDs
    }
}

// MARK: - Platform Access Methods
extension SupportedPlatform {
    /// Get a platform by its ID
    static func platform(for id: PlatformID) -> SupportedPlatform? {
        return all.first { $0.id == id.rawValue }
    }
    
    /// Check if a bundle ID belongs to this platform
    func contains(bundleID: String) -> Bool {
        return microphoneBundleIDs?.contains(bundleID) ?? false
    }
    
    /// Check if a window title matches this platform
    func matches(windowTitle: String) -> Bool {
        guard let keywords = windowTitleKeywords else { return false }
        return keywords.contains { windowTitle.localizedCaseInsensitiveContains($0) }
    }
}

// MARK: - Static Platform Accessors
extension SupportedPlatform {
    // Desktop Apps
    static var microsoftTeams: SupportedPlatform? { platform(for: .microsoftTeams) }
    static var zoom: SupportedPlatform? { platform(for: .zoom) }
    static var slack: SupportedPlatform? { platform(for: .slack) }
    static var discord: SupportedPlatform? { platform(for: .discord) }
    static var webex: SupportedPlatform? { platform(for: .ciscoWebex) }
    static var goTo: SupportedPlatform? { platform(for: .goTo) }
    
    // Web Apps
    static var googleMeet: SupportedPlatform? { platform(for: .googleMeet) }
    
    // Browsers
    static var chrome: SupportedPlatform? { platform(for: .googleChrome) }
    static var safari: SupportedPlatform? { platform(for: .safari) }
    static var edge: SupportedPlatform? { platform(for: .edge) }
    static var firefox: SupportedPlatform? { platform(for: .firefox) }
}

// MARK: - Detection Helpers
extension SupportedPlatform {
    /// Find platform by bundle identifier
    static func from(bundleID: String) -> SupportedPlatform? {
        return all.first { $0.contains(bundleID: bundleID) }
    }
    
    /// Find platform by window title
    static func from(windowTitle: String) -> SupportedPlatform? {
        return all.first { $0.matches(windowTitle: windowTitle) }
    }
    
    /// Find platform by microphone usage string
    static func from(microphoneUsageString: String) -> SupportedPlatform? {
        guard let bundleID = extractBundleID(from: microphoneUsageString) else {
            return nil
        }
        return from(bundleID: bundleID)
    }
    
    /// Get all platforms of a specific type
    static func platforms(ofType type: PlatformType) -> [SupportedPlatform] {
        return all.filter { $0.type == type }
    }
    
    /// Check if a bundle ID belongs to any browser
    static func isBrowser(bundleID: String) -> Bool {
        return platforms(ofType: .browser).contains { $0.contains(bundleID: bundleID) }
    }
    
    /// Check if a bundle ID belongs to any desktop app
    static func isDesktopApp(bundleID: String) -> Bool {
        return platforms(ofType: .desktop).contains { $0.contains(bundleID: bundleID) }
    }
    
    private static func extractBundleID(from usageString: String) -> String? {
        var cleanedString = usageString
        
        if cleanedString.hasPrefix("\"") && cleanedString.hasSuffix("\"") {
            cleanedString = String(cleanedString.dropFirst().dropLast())
        }
        
        if cleanedString.hasPrefix("mic:") {
            cleanedString = String(cleanedString.dropFirst(4))
        }
        
        return cleanedString.isEmpty ? nil : cleanedString
    }
}

// MARK: - Platform Definitions
extension SupportedPlatform {
    /// Returns a list of all platforms categorized as Desktop Apps.
    static var desktopApps: [SupportedPlatform] {
        return Self.all.filter { $0.type == .desktop }
    }
    
    /// Returns a list of all platforms categorized as Web Apps or Browsers.
    static var webAndBrowserApps: [SupportedPlatform] {
        return Self.all.filter { $0.type == .web || $0.type == .browser }
    }
    
    /// Returns a sorted list of the names of all supported platforms.
    static var allPlatformNames: [String] {
        return Self.all.map { $0.name }.sorted()
    }
    
    /// Returns a dictionary of platform names, categorized by type.
    static var categorizedPlatformNames: [String: [String]] {
        return [
            "all": self.all.map { $0.name }.sorted(),
            "desktop": self.desktopApps.map { $0.name }.sorted(),
            "webAndBrowser": self.webAndBrowserApps.map { $0.name }.sorted()
        ]
    }
    
    static let all: [SupportedPlatform] = [
        // Desktop Apps with both Window Title and Microphone detection
        .init(
            id: PlatformID.microsoftTeams.rawValue,
            name: "Microsoft Teams",
            type: .desktop,
//            windowTitleKeywords: ["(Meeting) | Microsoft Teams classic", "Microsoft Teams Meeting"],
            microphoneBundleIDs: [BundleID.teams]
        ),
        .init(
            id: PlatformID.ciscoWebex.rawValue,
            name: "Cisco Webex",
            type: .desktop,
            windowTitleKeywords: ["Cisco Webex"],
            microphoneBundleIDs: [BundleID.webex]
        ),
        .init(
            id: PlatformID.goTo.rawValue,
            name: "GoTo",
            type: .desktop,
            windowTitleKeywords: ["GoTo Meeting"],
            microphoneBundleIDs: [BundleID.goTo]
        ),
        
        .init(
              id: PlatformID.lark.rawValue,
              name: "Lark",
              type: .desktop,
              microphoneBundleIDs: [BundleID.lark]
        ),
        
        // Web Apps (primarily detected by Window Title)
        .init(
            id: PlatformID.googleMeet.rawValue,
            name: "Google Meet",
            type: .web,
            windowTitleKeywords: ["Meet -"],
            compatibleBrowserIDs: [.googleChrome, .safari, .edge, .firefox, .comet, .dia, .brave, .zen]
        ),
        
        // Desktop Apps (primarily detected by Microphone)
        .init(
            id: PlatformID.zoom.rawValue,
            name: "Zoom",
            type: .desktop,
            microphoneBundleIDs: [BundleID.zoom]
        ),
        .init(
            id: PlatformID.slack.rawValue,
            name: "Slack",
            type: .desktop,
            microphoneBundleIDs: [BundleID.slack]
        ),
        .init(
            id: PlatformID.discord.rawValue,
            name: "Discord",
            type: .desktop,
            microphoneBundleIDs: [BundleID.discord]
        ),
        
        // Browsers
        .init(
            id: PlatformID.googleChrome.rawValue,
            name: "Google Chrome",
            type: .browser,
            microphoneBundleIDs: [BundleID.chrome]
        ),
        .init(
            id: PlatformID.safari.rawValue,
            name: "Safari",
            type: .browser,
            microphoneBundleIDs: [BundleID.safari]
        ),
        .init(
            id: PlatformID.edge.rawValue,
            name: "Microsoft Edge",
            type: .browser,
            microphoneBundleIDs: [BundleID.edge]
        ),
        .init(
            id: PlatformID.firefox.rawValue,
            name: "Firefox",
            type: .browser,
            microphoneBundleIDs: [BundleID.firefox]
        ),
        
        // New Browsers now defined as supported platforms.
        .init(
            id: PlatformID.comet.rawValue,
            name: "Comet",
            type: .browser,
            microphoneBundleIDs: [BundleID.comet]
        ),
        .init(
            id: PlatformID.brave.rawValue,
            name: "Brave Browser",
            type: .browser,
            microphoneBundleIDs: [BundleID.brave]
        ),
        .init(
            id: PlatformID.zen.rawValue,
            name: "Zen Browser",
            type: .browser,
            microphoneBundleIDs: [BundleID.zen]
        ),
        .init(
            id: PlatformID.dia.rawValue,
            name: "Dia Browser",
            type: .browser,
            microphoneBundleIDs: [BundleID.dia]
        ),
        .init(
            id: PlatformID.atlas.rawValue,
            name: "Atlas Browser",
            type: .browser,
            microphoneBundleIDs: [BundleID.atlas]
        ),
        .init(
            id: PlatformID.arc.rawValue,
            name: "Arc Browser",
            type: .browser,
            microphoneBundleIDs: [BundleID.arc]
        ),
        
        .init(
            id: PlatformID.googleMeetPWA.rawValue,
            name: "Google Meet PWA",
            type: .web,
            windowTitleKeywords: ["Google Meet - Meet -"],
            compatibleBrowserIDs: [.googleChrome],
            microphoneBundleIDs: [BundleID.chrome]
        ),
    ]
}
