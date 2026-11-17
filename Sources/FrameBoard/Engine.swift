import Foundation
import AppKit

enum FrameBoardEngineError: LocalizedError {
    case missingPython
    case missingScript
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingPython:
            return "Не найден Python с OpenCV/InsightFace. Установите зависимости из engine/requirements.txt."
        case .missingScript:
            return "Не найден движок frameboard_engine.py."
        case .failed(let msg):
            return msg
        }
    }
}

final class FrameBoardEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var runningProcess: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let proc = runningProcess
        lock.unlock()
        proc?.terminate()
    }

    static func locatePython() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("engine/.venv/bin/python3"))
        }
        candidates += [
            home.appendingPathComponent("Documents/Проекты Антона/Приложения и инструменты/FrameBoard/engine/.venv/bin/python3"),
            home.appendingPathComponent("Documents/M24Workspace/StopFrames/.venv/bin/python"),
            home.appendingPathComponent("Documents/Проекты Антона/Приложения и инструменты/M24Workspace/StopFrames/.venv/bin/python"),
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            URL(fileURLWithPath: "/usr/bin/python3"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func locateScript() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("engine/frameboard_engine.py"))
        }
        candidates += [
            home.appendingPathComponent("Documents/Проекты Антона/Приложения и инструменты/FrameBoard/engine/frameboard_engine.py"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func analyze(
        videoURL: URL,
        mode: FrameBoardMode,
        intervalSeconds: Double,
        perPerson: Int,
        sceneThreshold: Double,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FrameBoardProject {
        guard let pythonURL = Self.locatePython() else {
            throw FrameBoardEngineError.missingPython
        }
        guard let scriptURL = Self.locateScript() else {
            throw FrameBoardEngineError.missingScript
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    self.lock.lock(); self.cancelled = false; self.lock.unlock()

                    var args = [scriptURL.path, videoURL.path]
                    switch mode {
                    case .facesFirstMinute:
                        args += ["--mode", "faces", "--max-seconds", "60", "--per-person", "\(perPerson)"]
                    case .facesFull:
                        args += ["--mode", "faces", "--max-seconds", "0", "--per-person", "\(perPerson)"]
                    case .storyboardScene:
                        args += ["--mode", "storyboard", "--storyboard-mode", "scene", "--scene-threshold", String(format: "%.2f", sceneThreshold), "--max-frames", "60"]
                    case .storyboardInterval:
                        args += ["--mode", "storyboard", "--storyboard-mode", "interval", "--interval", String(format: "%.1f", intervalSeconds), "--max-frames", "60"]
                    }

                    let proc = Process()
                    proc.executableURL = pythonURL
                    proc.arguments = args
                    proc.qualityOfService = .userInitiated

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    proc.standardOutput = stdoutPipe
                    proc.standardError = stderrPipe

                    self.lock.lock(); self.runningProcess = proc; self.lock.unlock()
                    try proc.run()

                    var pending = Data()
                    var resultPayload: [String: Any]?
                    var resultData: Data?
                    var errorMessage: String?

                    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty else { return }
                        pending.append(data)
                        while let nl = pending.firstIndex(of: 10) {
                            let lineData = pending.prefix(upTo: nl)
                            pending.removeSubrange(...nl)
                            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                                  let type = json["type"] as? String else { continue }
                            if type == "progress" {
                                let frac = json["fraction"] as? Double ?? 0
                                let msg = json["message"] as? String ?? "Обработка…"
                                progress(frac, msg)
                            } else if type == "result" {
                                resultPayload = json
                                resultData = Data(lineData)
                            } else if type == "error" {
                                errorMessage = json["message"] as? String
                            }
                        }
                    }

                    proc.waitUntilExit()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    let errBytes = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    self.lock.lock(); self.runningProcess = nil; let wasCancelled = self.cancelled; self.lock.unlock()
                    if wasCancelled {
                        throw CancellationError()
                    }
                    if let errorMessage {
                        throw FrameBoardEngineError.failed(errorMessage)
                    }
                    guard proc.terminationStatus == 0, let payload = resultPayload, let rData = resultData else {
                        let errStr = String(data: errBytes, encoding: .utf8) ?? "Неизвестная ошибка движка"
                        throw FrameBoardEngineError.failed(String(errStr.suffix(1200)))
                    }

                    struct RawResult: Decodable {
                        let output_dir: String
                        let contact_sheet: String?
                        let video_duration: Double?
                        let avg_shot_seconds: Double?
                        let elapsed_seconds: Double?
                        let storyboard_frames: [FrameShot]?
                        let people: [PersonCluster]?
                    }

                    let decoded = try JSONDecoder().decode(RawResult.self, from: rData)
                    let project = FrameBoardProject(
                        id: UUID(),
                        videoPath: videoURL.path,
                        title: videoURL.deletingPathExtension().lastPathComponent,
                        mode: mode,
                        createdAt: Date(),
                        outputDir: decoded.output_dir,
                        contactSheetPath: decoded.contact_sheet,
                        videoDuration: decoded.video_duration ?? 0,
                        avgShotSeconds: decoded.avg_shot_seconds ?? 0,
                        elapsedSeconds: decoded.elapsed_seconds ?? 0,
                        shots: decoded.storyboard_frames ?? [],
                        people: decoded.people ?? []
                    )
                    _ = payload
                    continuation.resume(returning: project)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func renderDirectorHTML(_ project: FrameBoardProject) -> String {
        let cardsHTML = project.shots.map { shot in
            let swatches = shot.palette.map { hex in
                "<span style=\"display:inline-block;width:22px;height:14px;border-radius:3px;background:\(hex);border:1px solid rgba(255,255,255,0.2);\" title=\"\(hex)\"></span>"
            }.joined(separator: " ")
            let hexList = shot.palette.joined(separator: " ")
            let durBadge = shot.durationSec > 0 ? " · \(String(format: "%.1f", shot.durationSec))s" : ""
            let personBadge = shot.person.map { " · \($0)" } ?? ""
            let noteText = shot.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let noteHTML = noteText.isEmpty ? "<span style=\"color:#64748b;font-style:italic;\">Без заметки</span>" : noteText.replacingOccurrences(of: "<", with: "&lt;")
            return """
            <div style="background:#131722;border:1px solid rgba(255,255,255,0.08);border-radius:12px;overflow:hidden;break-inside:avoid;">
              <img src="file://\(shot.path)" style="width:100%;aspect-ratio:16/9;object-fit:cover;display:block;">
              <div style="padding:12px;">
                <div style="font-family:monospace;font-size:12px;color:#fbbf24;margin-bottom:6px;">#\(shot.index) · \(shot.timestamp)\(durBadge)\(personBadge)</div>
                <div style="display:flex;gap:4px;align-items:center;margin-bottom:8px;">\(swatches)</div>
                <div style="font-size:10px;color:#94a3b8;font-family:monospace;margin-bottom:8px;">\(hexList)</div>
                <div style="font-size:13px;color:#e2e8f0;line-height:1.45;">\(noteHTML)</div>
              </div>
            </div>
            """
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="ru">
        <head>
        <meta charset="utf-8">
        <title>FrameBoard — \(project.title)</title>
        <style>
          body{margin:0;padding:32px;background:#0a0d14;color:#f8fafc;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;}
          .head{margin-bottom:24px;border-bottom:1px solid rgba(255,255,255,0.1);padding-bottom:16px;}
          .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:16px;}
        </style>
        </head>
        <body>
          <div class="head">
            <h1 style="margin:0 0 6px;">\(project.title)</h1>
            <div style="color:#94a3b8;font-size:14px;">Режим: \(project.mode.title) · Кадров: \(project.shots.count) · Средний план: \(String(format: "%.1f", project.avgShotSeconds))с</div>
          </div>
          <div class="grid">
            \(cardsHTML)
          </div>
        </body>
        </html>
        """
    }
}
