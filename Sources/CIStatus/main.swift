import AppKit
import Combine
import Foundation
import SwiftUI

@main
struct CIStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ActionsStatusModel()
    private var statusMenuController: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenuController = StatusMenuController(model: model)
    }
}

@MainActor
final class ActionsStatusModel: ObservableObject {
    @Published var repository: String {
        didSet {
            UserDefaults.standard.set(repository, forKey: "repository")
        }
    }

    @Published var refreshInterval: Double {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            startPolling()
        }
    }

    @Published private(set) var runs: [WorkflowRun] = []
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var lastUpdated: Date?

    private let client = GitHubActionsClient()
    private var refreshTask: Task<Void, Never>?

    var menuTitle: String {
        switch state {
        case .loading:
            return "🔵 CI ..."
        case .failed:
            return "🔴 CI ?"
        case .idle where runs.isEmpty:
            return "CI"
        default:
            return latestRun?.compactStatusTitle ?? "CI"
        }
    }

    var menuIcon: String {
        switch latestRun?.statusKind {
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.circle.fill"
        case .running:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .queued:
            return "clock.fill"
        case .cancelled:
            return "slash.circle.fill"
        case .none:
            return "circle.dashed"
        }
    }

    var latestRun: WorkflowRun? {
        runs.first
    }

    init() {
        repository = UserDefaults.standard.string(forKey: "repository") ?? ProcessInfo.processInfo.environment["GITHUB_REPOSITORY"] ?? ""
        let savedRefreshInterval = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = savedRefreshInterval == 0 ? 60 : savedRefreshInterval
        startPolling()
    }

    deinit {
        refreshTask?.cancel()
    }

    func startPolling() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                let seconds = max(self.refreshInterval, 15)
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func refresh() async {
        let trimmedRepository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepository.isEmpty else {
            runs = []
            state = .idle
            return
        }

        state = .loading
        do {
            runs = try await client.fetchRuns(repository: trimmedRepository)
            lastUpdated = Date()
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func openLatestRun() {
        guard let url = latestRun?.htmlURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openRun(_ run: WorkflowRun) {
        NSWorkspace.shared.open(run.htmlURL)
    }

    func openRepositoryActions() {
        let trimmedRepository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepository.isEmpty,
              let url = URL(string: "https://github.com/\(trimmedRepository)/actions") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}

enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
final class StatusMenuController {
    private let model: ActionsStatusModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let settingsWindowController: SettingsWindowController
    private var cancellables: Set<AnyCancellable> = []

    init(model: ActionsStatusModel) {
        self.model = model
        settingsWindowController = SettingsWindowController(model: model)

        menu.autoenablesItems = false
        statusItem.menu = menu

        if let button = statusItem.button {
            button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        }

        bindModel()
        rebuild()
    }

    private func bindModel() {
        Publishers.MergeMany([
            model.$repository.map { _ in () }.eraseToAnyPublisher(),
            model.$refreshInterval.map { _ in () }.eraseToAnyPublisher(),
            model.$runs.map { _ in () }.eraseToAnyPublisher(),
            model.$state.map { _ in () }.eraseToAnyPublisher(),
            model.$lastUpdated.map { _ in () }.eraseToAnyPublisher()
        ])
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            self?.rebuild()
        }
        .store(in: &cancellables)
    }

    private func rebuild() {
        statusItem.button?.title = model.menuTitle

        menu.removeAllItems()

        let trimmedRepository = model.repository.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRepository.isEmpty {
            addInfoRow(title: "No repository configured", subtitle: "Choose a repo to watch", icon: .settings)
            addActionRow(title: "Set Repository", icon: .settings) { [weak self] in
                self?.showSettings()
            }
            addSeparator()
        } else {
            addInfoRow(title: trimmedRepository, subtitle: nil, icon: .repository)
            addStatusSummary()
            addSeparator()

            addActionRow(title: "Open Actions", icon: .externalLink) { [weak self] in
                self?.model.openRepositoryActions()
            }

            addActionRow(title: "Open Latest Run", icon: .bolt, isEnabled: model.latestRun != nil) { [weak self] in
                self?.model.openLatestRun()
            }

            addSeparator()

            if model.runs.isEmpty {
                addInfoRow(title: "No workflow runs", subtitle: nil, icon: .empty)
            } else {
                for run in model.runs.prefix(5) {
                    addRunRow(run)
                }
            }

            addSeparator()
            addActionRow(title: "Settings", icon: .settings) { [weak self] in
                self?.showSettings()
            }
        }

        addActionRow(title: "Refresh", icon: .refresh) { [weak self] in
            Task {
                await self?.model.refresh()
            }
        }

        addSeparator()

        addActionRow(title: "Quit CIStatus", icon: .power) { [weak self] in
            self?.model.quit()
        }
    }

    private func addStatusSummary() {
        switch model.state {
        case .loading where model.runs.isEmpty:
            addInfoRow(title: "Loading...", subtitle: nil, icon: .status(.running))
        case .failed(let message):
            addInfoRow(title: "Could not load Actions", subtitle: message, icon: .status(.failure))
        default:
            if let latestRun = model.latestRun {
                let subtitle = model.lastUpdated.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" }
                addInfoRow(title: latestRun.displayTitle, subtitle: subtitle, icon: .status(latestRun.statusKind))
            } else {
                addInfoRow(title: "Waiting for status", subtitle: nil, icon: .empty)
            }
        }
    }

    private func addRunRow(_ run: WorkflowRun) {
        addActionRow(title: run.displayTitle, subtitle: run.detail, icon: .status(run.statusKind)) { [weak self] in
            self?.model.openRun(run)
        }
    }

    private func addInfoRow(title: String, subtitle: String?, icon: MenuIcon) {
        addCustomItem(title: title, subtitle: subtitle, icon: icon, isEnabled: false, action: nil)
    }

    private func addActionRow(title: String, subtitle: String? = nil, icon: MenuIcon, isEnabled: Bool = true, action: @escaping () -> Void) {
        addCustomItem(title: title, subtitle: subtitle, icon: icon, isEnabled: isEnabled, action: action)
    }

    private func addCustomItem(title: String, subtitle: String?, icon: MenuIcon, isEnabled: Bool, action: (() -> Void)?) {
        let item = NSMenuItem()
        item.isEnabled = isEnabled

        let height: CGFloat = subtitle == nil ? 34 : 48
        let row = MenuRowView(
            title: title,
            subtitle: subtitle,
            icon: icon,
            isEnabled: isEnabled,
            isInteractive: action != nil,
            action: { [weak self] in
                self?.menu.cancelTracking()
                action?()
            }
        )
        let hostingView = NSHostingView(rootView: row)
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: height)
        item.view = hostingView
        menu.addItem(item)
    }

    private func addSeparator() {
        menu.addItem(.separator())
    }

    private func showSettings() {
        settingsWindowController.show()
    }
}

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(model: ActionsStatusModel) {
        let hostingController = NSHostingController(rootView: SettingsView(model: model))
        window = NSWindow(contentViewController: hostingController)
        window.title = "CIStatus Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

enum MenuIcon {
    case status(StatusKind)
    case repository
    case externalLink
    case bolt
    case settings
    case refresh
    case power
    case empty
}

struct MenuRowView: View {
    let title: String
    let subtitle: String?
    let icon: MenuIcon
    let isEnabled: Bool
    let isInteractive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: subtitle == nil ? .regular : .medium))
                    .lineLimit(1)
                    .foregroundStyle(foregroundStyle)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, subtitle == nil ? 7 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering in
            isHovered = hovering && isEnabled && isInteractive
        }
        .onTapGesture {
            guard isEnabled, isInteractive else { return }
            action()
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .status(let statusKind):
            ZStack {
                Circle()
                    .fill(statusKind.color)
                    .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
                    .shadow(color: statusKind.color.opacity(0.45), radius: 1.5, y: 1)

                Image(systemName: statusKind.badgeSymbolName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .repository:
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
        case .externalLink:
            Image(systemName: "arrow.up.right.square")
                .foregroundStyle(.secondary)
        case .bolt:
            Image(systemName: "bolt.fill")
                .foregroundStyle(.orange)
        case .settings:
            Image(systemName: "gearshape")
                .foregroundStyle(.secondary)
        case .refresh:
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(.secondary)
        case .power:
            Image(systemName: "power")
                .foregroundStyle(.secondary)
        case .empty:
            Circle()
                .stroke(.secondary.opacity(0.5), lineWidth: 1.5)
        }
    }

    private var background: some ShapeStyle {
        isHovered ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Color.clear)
    }

    private var foregroundStyle: some ShapeStyle {
        isHovered ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.primary)
    }
}

struct SettingsView: View {
    @ObservedObject var model: ActionsStatusModel

    var body: some View {
        Form {
            TextField("Repository", text: $model.repository, prompt: Text("owner/repo"))
                .onSubmit {
                    Task { await model.refresh() }
                }

            Stepper(value: $model.refreshInterval, in: 15...600, step: 15) {
                Text("Refresh every \(Int(model.refreshInterval)) seconds")
            }

            HStack {
                Spacer()
                Button("Refresh Now") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
    }
}

struct GitHubActionsClient {
    func fetchRuns(repository: String) async throws -> [WorkflowRun] {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/actions/runs?per_page=10") else {
            throw ClientError.invalidRepository
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CIStatus", forHTTPHeaderField: "User-Agent")

        if let token = Self.token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(APIError.self, from: data)
            throw ClientError.api(httpResponse.statusCode, apiError?.message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkflowRunsResponse.self, from: data).workflowRuns
    }

    private static func token() -> String? {
        if let environmentToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"],
           !environmentToken.isEmpty {
            return environmentToken
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/gh")
        process.arguments = ["auth", "token"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

struct WorkflowRunsResponse: Decodable {
    let workflowRuns: [WorkflowRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

struct WorkflowRun: Decodable, Identifiable {
    let id: Int
    let name: String
    let event: String
    let status: String
    let conclusion: String?
    let branch: String
    let htmlURL: URL
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case event
        case status
        case conclusion
        case branch = "head_branch"
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var statusKind: StatusKind {
        if status == "queued" || status == "requested" || status == "waiting" || status == "pending" {
            return .queued
        }

        if status != "completed" {
            return .running
        }

        switch conclusion {
        case "success":
            return .success
        case "cancelled", "skipped", "neutral":
            return .cancelled
        default:
            return .failure
        }
    }

    var compactStatus: String {
        switch statusKind {
        case .success:
            return "CI OK"
        case .failure:
            return "CI Failed"
        case .running:
            return "CI Running"
        case .queued:
            return "CI Queued"
        case .cancelled:
            return "CI Stopped"
        }
    }

    var compactStatusTitle: String {
        "\(statusKind.symbol) \(compactStatus)"
    }

    var detail: String {
        let statusText = conclusion ?? status
        return "\(branch) - \(event) - \(statusText)"
    }

    var menuTitle: String {
        "\(statusKind.symbol) \(name) - \(branch)"
    }

    var displayTitle: String {
        "\(name) - \(branch)"
    }
}

enum StatusKind {
    case success
    case failure
    case running
    case queued
    case cancelled

    var iconName: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.circle.fill"
        case .running:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .queued:
            return "clock.fill"
        case .cancelled:
            return "slash.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success:
            return .green
        case .failure:
            return .red
        case .running:
            return .blue
        case .queued:
            return .orange
        case .cancelled:
            return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .success:
            return "🟢"
        case .failure:
            return "🔴"
        case .running:
            return "🔵"
        case .queued:
            return "🟠"
        case .cancelled:
            return "⚪"
        }
    }

    var badgeSymbolName: String {
        switch self {
        case .success:
            return "checkmark"
        case .failure:
            return "xmark"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .queued:
            return "clock.fill"
        case .cancelled:
            return "slash"
        }
    }
}

struct APIError: Decodable {
    let message: String
}

enum ClientError: LocalizedError {
    case invalidRepository
    case invalidResponse
    case api(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "Repository must be in owner/repo format."
        case .invalidResponse:
            return "GitHub returned an unreadable response."
        case .api(let statusCode, let message):
            if let message {
                return "GitHub returned \(statusCode): \(message)"
            }
            return "GitHub returned \(statusCode)."
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
