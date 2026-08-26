import Foundation

enum StreamPreset: String, CaseIterable, Identifiable {
    case ultra = "4K / 120"
    case high = "4K / 60"
    case fast = "1080p / 120"
    case balanced = "1080p / 60"

    var id: String { rawValue }

    var width: Int32 {
        switch self {
        case .ultra, .high: return 3840
        case .fast, .balanced: return 1920
        }
    }

    var height: Int32 {
        switch self {
        case .ultra, .high: return 2160
        case .fast, .balanced: return 1080
        }
    }

    var fps: Int32 {
        switch self {
        case .ultra, .fast: return 120
        case .high, .balanced: return 60
        }
    }

    var bitrate: Int {
        switch self {
        case .ultra: return 120_000_000
        case .high: return 80_000_000
        case .fast: return 50_000_000
        case .balanced: return 35_000_000
        }
    }
}

