import Foundation

enum FrameBoardMode: String, Codable, CaseIterable, Identifiable {
    case facesFirstMinute = "faces_60"
    case facesFull = "faces_full"
    case storyboardScene = "sb_scene"
    case storyboardInterval = "sb_interval"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .facesFirstMinute: return "Лица · Первая минута (быстро)"
        case .facesFull: return "Лица · Всё видео"
        case .storyboardScene: return "Раскадровка · По смене сцен"
        case .storyboardInterval: return "Раскадровка · Посекундно"
        }
    }

    var shortBadge: String {
        switch self {
        case .facesFirstMinute: return "Лица · 60с"
        case .facesFull: return "Лица · Всё"
        case .storyboardScene: return "Сцены"
        case .storyboardInterval: return "Посекундно"
        }
    }

    var isFaces: Bool {
        self == .facesFirstMinute || self == .facesFull
    }
}

struct FrameShot: Codable, Identifiable, Hashable {
    var id: Int { index }
    let index: Int
    let seconds: Double
    let durationSec: Double
    let timestamp: String
    let path: String
    let palette: [String]
    var person: String?
    var note: String = ""

    var url: URL { URL(fileURLWithPath: path) }

    enum CodingKeys: String, CodingKey {
        case index, seconds, timestamp, path, palette, person, note
        case durationSec = "duration_sec"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        durationSec = try c.decodeIfPresent(Double.self, forKey: .durationSec) ?? 0
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp) ?? "00:00"
        path = try c.decode(String.self, forKey: .path)
        palette = try c.decodeIfPresent([String].self, forKey: .palette) ?? []
        person = try c.decodeIfPresent(String.self, forKey: .person)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct PersonCluster: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let screenTimeSeconds: Double
    let frames: [String]

    enum CodingKeys: String, CodingKey {
        case name, frames
        case screenTimeSeconds = "screen_time_seconds"
    }
}

struct FrameBoardProject: Codable, Identifiable, Hashable {
    let id: UUID
    let videoPath: String
    var title: String
    var mode: FrameBoardMode
    var createdAt: Date
    var outputDir: String
    var contactSheetPath: String?
    var videoDuration: Double
    var avgShotSeconds: Double
    var elapsedSeconds: Double
    var shots: [FrameShot]
    var people: [PersonCluster]

    var videoURL: URL { URL(fileURLWithPath: videoPath) }
    var outputURL: URL { URL(fileURLWithPath: outputDir) }
    var contactSheetURL: URL? { contactSheetPath.map { URL(fileURLWithPath: $0) } }
}

enum FrameBoardPaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FrameBoard", isDirectory: true)
    static let history = root.appendingPathComponent("projects.json")

    static func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
