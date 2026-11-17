import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var projects: [FrameBoardProject] = []
    @Published var selectedID: UUID?
    @Published var pendingVideoURL: URL?

    @Published var mode: FrameBoardMode = .storyboardScene
    @Published var intervalSeconds: Double = 1.0
    @Published var perPerson: Int = 3
    @Published var sceneThreshold: Double = 0.30

    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var statusText = "Перетащите видео или выберите файл"
    @Published var notice: String?
    @Published var lightboxShotIndex: Int?

    private let engine = FrameBoardEngine()

    init() {
        loadHistory()
    }

    var selectedProject: FrameBoardProject? {
        get { projects.first(where: { $0.id == selectedID }) }
        set {
            guard let v = newValue, let idx = projects.firstIndex(where: { $0.id == v.id }) else { return }
            projects[idx] = v
        }
    }

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.title = "Выберите видео для разбора"
        panel.prompt = "Открыть"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        if panel.runModal() == .OK, let url = panel.url {
            importVideo(url, autoStart: true)
        }
    }

    func importVideo(_ url: URL, autoStart: Bool = true) {
        let allowed = Set(["mp4", "mov", "m4v", "mkv", "avi", "webm"])
        guard allowed.contains(url.pathExtension.lowercased()) else {
            notice = "Поддерживаются только видеофайлы (MP4, MOV, M4V, MKV)."
            return
        }
        pendingVideoURL = url
        if autoStart && !isRunning {
            runAnalysis(for: url)
        }
    }

    func runAnalysis(for url: URL? = nil) {
        let targetURL = url ?? pendingVideoURL ?? selectedProject?.videoURL
        guard let targetURL, !isRunning else { return }
        isRunning = true
        progress = 0.02
        statusText = "Запуск анализа…"

        let chosenMode = mode
        let chosenInterval = intervalSeconds
        let chosenPerPerson = perPerson
        let chosenThreshold = sceneThreshold

        Task {
            do {
                let project = try await engine.analyze(
                    videoURL: targetURL,
                    mode: chosenMode,
                    intervalSeconds: chosenInterval,
                    perPerson: chosenPerPerson,
                    sceneThreshold: chosenThreshold
                ) { frac, msg in
                    Task { @MainActor in
                        self.progress = frac
                        self.statusText = msg
                    }
                }
                self.projects.insert(project, at: 0)
                self.selectedID = project.id
                self.pendingVideoURL = nil
                self.isRunning = false
                self.progress = 1.0
                self.statusText = "Готово"
                self.saveHistory()
            } catch is CancellationError {
                self.isRunning = false
                self.statusText = "Отменено"
            } catch {
                self.isRunning = false
                self.notice = error.localizedDescription
                self.statusText = "Ошибка"
            }
        }
    }

    func cancelAnalysis() {
        engine.cancel()
    }

    func updateNote(projectID: UUID, shotIndex: Int, note: String) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let sIdx = projects[pIdx].shots.firstIndex(where: { $0.index == shotIndex }) else { return }
        projects[pIdx].shots[sIdx].note = note
        saveHistory()
    }

    func deleteShot(projectID: UUID, shotIndex: Int) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[pIdx].shots.removeAll { $0.index == shotIndex }
        saveHistory()
    }

    func deleteProject(_ id: UUID) {
        if selectedID == id { selectedID = nil }
        projects.removeAll { $0.id == id }
        saveHistory()
    }

    func copyImage(_ url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        notice = "Кадр скопирован в буфер обмена."
    }

    func copyHex(_ hex: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        notice = "Цвет \(hex) скопирован."
    }

    func exportDirectorHTML() {
        guard let project = selectedProject else { return }
        let dest = project.outputURL.appendingPathComponent("\(project.title)_режиссерский_лист.html")
        do {
            try FrameBoardEngine.renderDirectorHTML(project).write(to: dest, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(dest)
        } catch {
            notice = "Не удалось сохранить HTML: \(error.localizedDescription)"
        }
    }

    func exportMarkdown() {
        guard let project = selectedProject else { return }
        var md = "# \(project.title)\n\n"
        md += "- Режим: \(project.mode.title)\n"
        md += "- Кадров: \(project.shots.count)\n"
        if project.avgShotSeconds > 0 {
            md += "- Средняя длина плана: \(String(format: "%.1f", project.avgShotSeconds)) сек\n"
        }
        md += "\n---\n\n"
        for shot in project.shots {
            md += "### #\(shot.index) · \(shot.timestamp)"
            if shot.durationSec > 0 { md += " (\(String(format: "%.1f", shot.durationSec))с)" }
            if let person = shot.person { md += " · \(person)" }
            md += "\n"
            if !shot.palette.isEmpty {
                md += "Палитра: `\(shot.palette.joined(separator: "  "))`\n"
            }
            if !shot.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                md += "Заметка: \(shot.note)\n"
            }
            md += "\n"
        }
        let dest = project.outputURL.appendingPathComponent("\(project.title)_раскадровка.md")
        do {
            try md.write(to: dest, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            notice = "Не удалось сохранить Markdown: \(error.localizedDescription)"
        }
    }

    private func loadHistory() {
        try? FrameBoardPaths.prepare()
        guard let data = try? Data(contentsOf: FrameBoardPaths.history),
              let decoded = try? JSONDecoder().decode([FrameBoardProject].self, from: data) else { return }
        projects = decoded
    }

    private func saveHistory() {
        try? FrameBoardPaths.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(projects) {
            try? data.write(to: FrameBoardPaths.history, options: .atomic)
        }
    }
}
