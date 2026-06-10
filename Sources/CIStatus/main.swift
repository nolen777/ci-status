import AppKit
import Foundation
import SwiftUI

@main
struct CIStatusApp: App {
    @StateObject private var model = ActionsStatusModel()

    var body: some Scene {
        MenuBarExtra {
            StatusPanel(model: model)
                .frame(width: 360)
                .task {
                    await model.refresh()
                }
        } label: {
            Label(model.menuTitle, systemImage: model.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class ActionsStatusModel: ObservableObject {
    @AppStorage("repository") var repository: String = ProcessInfo.processInfo.environment["GITHUB_REPOSITORY"] ?? ""
    @AppStorage("refreshInterval") var refreshInterval: Double = 60

    @Published private(set) var runs: [WorkflowRun] = []
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var lastUpdated: Date?

    private let client = GitHubActionsClient()
    private var refreshTask: Task<Void, Never>?

    var menuTitle: String {
        switch state {
        case .loading:
            return "CI ..."
        case .failed:
            return "CI ?"
        case .idle where runs.isEmpty:
            return "CI"
        default:
            return latestRun?.compactStatus ?? "CI"
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

struct StatusPanel: View {
    @ObservedObject var model: ActionsStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            repositoryField
            Divider()
            content
            Divider()
            footer
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.menuIcon)
                .font(.title2)
                .foregroundStyle(statusColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.latestRun?.name ?? "GitHub Actions")
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
    }

    private var repositoryField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Repository")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("owner/repo", text: $model.repository)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { await model.refresh() }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle where model.repository.isEmpty:
            ContentUnavailableView("Choose a repository", systemImage: "tray", description: Text("Use owner/repo, like apple/swift."))
                .frame(height: 140)
        case .loading where model.runs.isEmpty:
            ProgressView("Loading runs...")
                .frame(maxWidth: .infinity, minHeight: 140)
        case .failed(let message):
            ContentUnavailableView("Could not load Actions", systemImage: "exclamationmark.triangle", description: Text(message))
                .frame(height: 140)
        default:
            VStack(spacing: 8) {
                ForEach(model.runs.prefix(5)) { run in
                    RunRow(run: run)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Actions") {
                model.openRepositoryActions()
            }
            .disabled(model.repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Open Latest") {
                model.openLatestRun()
            }
            .disabled(model.latestRun == nil)

            Spacer()

            Button("Quit") {
                model.quit()
            }
        }
        .buttonStyle(.borderless)
    }

    private var subtitle: String {
        if let lastUpdated = model.lastUpdated {
            return "Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))"
        }

        return "Waiting for status"
    }

    private var statusColor: Color {
        switch model.latestRun?.statusKind {
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
        case .none:
            return .secondary
        }
    }
}

struct RunRow: View {
    let run: WorkflowRun

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: run.statusKind.iconName)
                .foregroundStyle(run.statusKind.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(run.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(run.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.vertical, 4)
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

    var detail: String {
        let statusText = conclusion ?? status
        return "\(branch) - \(event) - \(statusText)"
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
