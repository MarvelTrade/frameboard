import SwiftUI
import UniformTypeIdentifiers

private let accent = Color(red: 0.96, green: 0.66, blue: 0.12)
private let cyanAccent = Color(red: 0.22, green: 0.74, blue: 0.97)
private let canvas = Color(red: 0.039, green: 0.051, blue: 0.078)
private let panelSurface = Color(red: 0.059, green: 0.075, blue: 0.114)
private let cardSurface = Color(red: 0.075, green: 0.094, blue: 0.141)
private let cardBorder = Color.white.opacity(0.08)

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var isDropTarget = false

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView().frame(width: 235)
                Divider()
                VStack(spacing: 0) {
                    TopBar()
                    ZStack {
                        canvas.ignoresSafeArea()
                        if let project = state.selectedProject {
                            ProjectDetailView(project: project)
                        } else {
                            HomeView(isDropTarget: $isDropTarget)
                        }
                    }
                }
            }

            if let idx = state.lightboxShotIndex, let project = state.selectedProject,
               let shot = project.shots.first(where: { $0.index == idx }) {
                LightboxOverlay(project: project, shot: shot)
            }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 880, minHeight: 560)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let text = String(data: data, encoding: .utf8), let url = URL(string: text) else { return }
                    Task { @MainActor in state.importVideo(url, autoStart: true) }
                }
            }
            return true
        }
        .alert("FrameBoard", isPresented: Binding(get: { state.notice != nil }, set: { if !$0 { state.notice = nil } })) {
            Button("Хорошо") { state.notice = nil }
        } message: { Text(state.notice ?? "") }
    }
}

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "rectangle.grid.2x2.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 38, height: 38)
                    .background(accent.gradient, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 1) {
                    Text("FrameBoard").font(.headline)
                    Text("Стоп-кадры и раскадровка").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(18)

            Button {
                state.selectedID = nil
            } label: {
                Label("Новый разбор", systemImage: "plus.square.on.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .background(state.selectedID == nil ? accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(state.selectedID == nil ? accent.opacity(0.35) : .clear, lineWidth: 1))
            .padding(.horizontal, 10)

            HStack {
                Text("ПРОЕКТЫ").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(state.projects.count)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 8)

            List(selection: $state.selectedID) {
                ForEach(state.projects) { project in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.title).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 6) {
                            Text(project.mode.shortBadge)
                                .foregroundStyle(project.mode.isFaces ? cyanAccent : accent)
                            Text("· \(project.shots.count) кадр.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption2)
                    }
                    .padding(.vertical, 4)
                    .tag(project.id)
                    .contextMenu {
                        Button("Открыть папку") { NSWorkspace.shared.open(project.outputURL) }
                        Button("Удалить из истории", role: .destructive) { state.deleteProject(project.id) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Button(action: state.openFilePanel) {
                Label("Открыть видео", systemImage: "film.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)

            Text("Антон Белый")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 10)
        }
        .background(panelSurface)
    }
}

struct TopBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            Text(state.selectedProject?.title ?? "FrameBoard — Студия раскадровки")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()

            HStack(spacing: 10) {
                Picker("Режим", selection: $state.mode) {
                    ForEach(FrameBoardMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .frame(width: 265)
                .disabled(state.isRunning)

                if state.mode == .storyboardInterval {
                    Picker("Шаг", selection: $state.intervalSeconds) {
                        Text("0.5 сек").tag(0.5)
                        Text("1 сек").tag(1.0)
                        Text("2 сек").tag(2.0)
                        Text("5 сек").tag(5.0)
                    }
                    .frame(width: 95)
                    .disabled(state.isRunning)
                } else if state.mode.isFaces {
                    Picker("Кадров", selection: $state.perPerson) {
                        Text("3 / чел").tag(3)
                        Text("5 / чел").tag(5)
                    }
                    .frame(width: 95)
                    .disabled(state.isRunning)
                }

                if state.selectedProject != nil && !state.isRunning {
                    Button {
                        state.runAnalysis()
                    } label: {
                        Label("Пересчитать", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(panelSurface.opacity(0.96))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct HomeView: View {
    @EnvironmentObject var state: AppState
    @Binding var isDropTarget: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Разберите видео на стоп-кадры и сцены")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Отбор лучших кадров ведущих за первую минуту или покадровая раскадровка клипа с цветовой палитрой и заметками.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 16) {
                    Image(systemName: state.isRunning ? "sparkles.rectangle.stack" : "film.stack.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(accent)
                        .symbolRenderingMode(.hierarchical)

                    if state.isRunning {
                        Text(state.statusText).font(.headline)
                        ProgressView(value: state.progress).frame(maxWidth: 380)
                        Button("Отменить", role: .destructive, action: state.cancelAnalysis)
                            .buttonStyle(.bordered)
                    } else {
                        Text("Перетащите видео сюда").font(.title2.bold())
                        Text("MP4, MOV, M4V, MKV · Анализ идёт локально на Mac").foregroundStyle(.secondary)
                        Button("Выбрать видео…", action: state.openFilePanel)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .background(isDropTarget ? accent.opacity(0.14) : cardSurface, in: RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(isDropTarget ? accent : Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [8]))
                )

                if !state.projects.isEmpty {
                    Text("Недавние разборы").font(.title3.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                        ForEach(state.projects.prefix(6)) { project in
                            Button {
                                state.selectedID = project.id
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    if let first = project.shots.first, let nsImg = NSImage(contentsOf: first.url) {
                                        Image(nsImage: nsImg)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(height: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    Text(project.title).font(.headline).lineLimit(1)
                                    HStack {
                                        Text(project.mode.shortBadge).foregroundStyle(accent)
                                        Text("· \(project.shots.count) кадр.")
                                        Spacer()
                                        Text(project.createdAt, style: .date)
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .background(cardSurface, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(cardBorder, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(28)
        }
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject var state: AppState
    let project: FrameBoardProject
    @State private var showContactSheet = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header stats & export bar
                HStack(spacing: 12) {
                    StatPill(label: "Режим", value: project.mode.shortBadge, color: accent)
                    StatPill(label: "Кадров", value: "\(project.shots.count)", color: cyanAccent)
                    if project.avgShotSeconds > 0 {
                        StatPill(label: "Средний план", value: "\(String(format: "%.1f", project.avgShotSeconds)) с", color: .green)
                    }
                    StatPill(label: "Обработано", value: "\(String(format: "%.1f", project.elapsedSeconds)) с", color: .secondary)

                    Spacer()

                    if let sheet = project.contactSheetURL {
                        Button { showContactSheet.toggle() } label: {
                            Label(showContactSheet ? "Скрыть таблицу" : "Таблица", systemImage: "tablecells")
                        }.buttonStyle(.bordered)
                        Button { NSWorkspace.shared.open(sheet) } label: {
                            Label("Таблица JPG", systemImage: "photo")
                        }.buttonStyle(.bordered)
                    }

                    Button(action: state.exportDirectorHTML) {
                        Label("Лист режиссёра (HTML)", systemImage: "doc.richtext")
                    }.buttonStyle(.borderedProminent)

                    Button(action: state.exportMarkdown) {
                        Label("Markdown", systemImage: "doc.text")
                    }.buttonStyle(.bordered)

                    Button { NSWorkspace.shared.open(project.outputURL) } label: {
                        Label("Папка", systemImage: "folder")
                    }.buttonStyle(.bordered)
                }

                // Contact sheet preview
                if showContactSheet, let sheetURL = project.contactSheetURL, let sheetImg = NSImage(contentsOf: sheetURL) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Сводная таблица-раскадровка (Contact Sheet)").font(.headline)
                            Spacer()
                            Button("Копировать таблицу") { state.copyImage(sheetURL) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                        Image(nsImage: sheetImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 340)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(cardBorder, lineWidth: 1))
                            .onTapGesture { NSWorkspace.shared.open(sheetURL) }
                    }
                    .padding(14)
                    .background(cardSurface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(cardBorder, lineWidth: 1))
                }

                // People summary (when in faces mode)
                if !project.people.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(project.people) { p in
                            HStack(spacing: 6) {
                                Image(systemName: "person.crop.circle.fill").foregroundStyle(cyanAccent)
                                Text(p.name).font(.subheadline.weight(.semibold))
                                Text("· в кадре \(Int(p.screenTimeSeconds))с").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(cardSurface, in: Capsule())
                            .overlay(Capsule().strokeBorder(cardBorder, lineWidth: 1))
                        }
                    }
                }

                // Storyboard shots grid with Color Swatches + Director Notes
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                    ForEach(project.shots) { shot in
                        ShotCardView(projectID: project.id, shot: shot)
                    }
                }
            }
            .padding(24)
        }
    }
}

struct StatPill: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(color)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(cardBorder, lineWidth: 1))
    }
}

struct ShotCardView: View {
    @EnvironmentObject var state: AppState
    let projectID: UUID
    let shot: FrameShot
    @State private var noteText: String

    init(projectID: UUID, shot: FrameShot) {
        self.projectID = projectID
        self.shot = shot
        _noteText = State(initialValue: shot.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if let img = NSImage(contentsOf: shot.url) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.lightboxShotIndex = shot.index
                        }
                }

                HStack(spacing: 6) {
                    Text("#\(shot.index) · \(shot.timestamp)")
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .foregroundStyle(accent)
                    if shot.durationSec > 0 {
                        Text("\(String(format: "%.1f", shot.durationSec))с")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    if let person = shot.person {
                        Text("· \(person)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(cyanAccent)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(8)
            }

            // Palette swatches + quick actions
            HStack(spacing: 6) {
                ForEach(shot.palette, id: \.self) { hex in
                    Button {
                        state.copyHex(hex)
                    } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: hex))
                            .frame(width: 24, height: 16)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Копировать цвет \(hex)")
                }

                Spacer()

                Button { state.copyImage(shot.url) } label: {
                    Image(systemName: "doc.on.doc")
                }.buttonStyle(.plain).help("Копировать кадр")

                Button { NSWorkspace.shared.activateFileViewerSelecting([shot.url]) } label: {
                    Image(systemName: "folder")
                }.buttonStyle(.plain).help("Показать в Finder")

                Button { state.deleteShot(projectID: projectID, shotIndex: shot.index) } label: {
                    Image(systemName: "trash").foregroundStyle(.red.opacity(0.8))
                }.buttonStyle(.plain).help("Удалить кадр")
            }
            .foregroundStyle(.secondary)
            .font(.caption)

            // Director's note
            TextField("Заметка режиссёра (свет, план, движение)…", text: $noteText)
                .textFieldStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(panelSurface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(cardBorder, lineWidth: 1))
                .onChange(of: noteText) { _, newValue in
                    state.updateNote(projectID: projectID, shotIndex: shot.index, note: newValue)
                }
        }
        .padding(12)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(cardBorder, lineWidth: 1))
    }
}

struct LightboxOverlay: View {
    @EnvironmentObject var state: AppState
    let project: FrameBoardProject
    let shot: FrameShot

    var body: some View {
        ZStack {
            Color.black.opacity(0.86).ignoresSafeArea()
                .onTapGesture { state.lightboxShotIndex = nil }

            VStack(spacing: 16) {
                HStack {
                    Text("#\(shot.index) · \(shot.timestamp)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(accent)
                    if shot.durationSec > 0 {
                        Text("· Длительность плана: \(String(format: "%.1f", shot.durationSec)) с")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Копировать кадр") { state.copyImage(shot.url) }.buttonStyle(.borderedProminent)
                    Button("Закрыть") { state.lightboxShotIndex = nil }.buttonStyle(.bordered)
                }

                if let img = NSImage(contentsOf: shot.url) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                HStack(spacing: 12) {
                    ForEach(shot.palette, id: \.self) { hex in
                        Button {
                            state.copyHex(hex)
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: hex)).frame(width: 16, height: 16)
                                Text(hex).font(.caption.monospaced())
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(cardSurface, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1000, maxHeight: 740)
            .background(panelSurface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
    }
}
