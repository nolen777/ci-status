import AppKit
import Combine
import Foundation
import SwiftUI

@main
struct CIStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
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
    @Published var availableRepositories: [String] {
        didSet {
            UserDefaults.standard.set(availableRepositories, forKey: "availableRepositories")
        }
    }

    @Published var selectedRepositories: [String] {
        didSet {
            UserDefaults.standard.set(selectedRepositories, forKey: "selectedRepositories")
            UserDefaults.standard.set(selectedRepositories.first ?? "", forKey: "repository")
        }
    }

    @Published var refreshInterval: Double {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            startPolling()
        }
    }

    @Published private(set) var runs: [WorkflowRun] = []
    @Published private(set) var runnerSummaries: [Int: RunnerSummary] = [:]
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
            return menuStatusKind.compactStatusTitle
        }
    }

    var menuIcon: String {
        switch menuStatusKind {
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

    var latestRun: WorkflowRun? {
        runs.first
    }

    var repositoryMenuTitle: String {
        switch selectedRepositories.count {
        case 0:
            return "Repositories"
        case 1:
            return selectedRepositories[0]
        default:
            return "\(selectedRepositories.count) repositories"
        }
    }

    var menuStatusKind: StatusKind {
        let sections = RunSections(runs: runs)
        if !sections.unresolvedFailures.isEmpty {
            return .failure
        }

        if !sections.activeRuns.isEmpty {
            return .running
        }

        return .success
    }

    var mainStatus: BranchStatus {
        BranchStatus(branch: "main", runs: runs)
    }

    init() {
        let legacyRepository = UserDefaults.standard.string(forKey: "repository") ?? ProcessInfo.processInfo.environment["GITHUB_REPOSITORY"] ?? ""
        let savedAvailableRepositories = UserDefaults.standard.stringArray(forKey: "availableRepositories") ?? []
        let savedSelectedRepositories = UserDefaults.standard.stringArray(forKey: "selectedRepositories") ?? []
        availableRepositories = Self.uniqueRepositories(savedAvailableRepositories + [legacyRepository])
        selectedRepositories = Self.uniqueRepositories(savedSelectedRepositories.isEmpty ? [legacyRepository] : savedSelectedRepositories)
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
        let repositories = Self.uniqueRepositories(selectedRepositories)
        guard !repositories.isEmpty else {
            runs = []
            runnerSummaries = [:]
            state = .idle
            return
        }

        state = .loading
        do {
            var fetchedRuns: [WorkflowRun] = []
            for repository in repositories {
                fetchedRuns += try await client.fetchRuns(repository: repository).map { run in
                    var repositoryRun = run
                    repositoryRun.sourceRepository = repository
                    return repositoryRun
                }
            }
            let sortedRuns = fetchedRuns.sorted { $0.createdAt > $1.createdAt }
            runs = sortedRuns
            runnerSummaries = [:]
            lastUpdated = Date()
            state = .loaded
            await refreshRunnerSummaries(for: RunSections(runs: sortedRuns).activeRuns)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func runnerSummary(for run: WorkflowRun) -> RunnerSummary? {
        runnerSummaries[run.id]
    }

    private func refreshRunnerSummaries(for activeRuns: [WorkflowRun]) async {
        guard !activeRuns.isEmpty else {
            runnerSummaries = [:]
            return
        }

        var summaries: [Int: RunnerSummary] = [:]
        for run in activeRuns.prefix(10) {
            guard let jobs = try? await client.fetchJobs(repository: run.sourceRepository, runID: run.id) else {
                continue
            }
            summaries[run.id] = RunnerSummary(jobs: jobs)
        }

        runnerSummaries = summaries
    }

    func openRun(_ run: WorkflowRun) {
        NSWorkspace.shared.open(run.htmlURL)
    }

    func toggleRepository(_ repository: String) {
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repository.isEmpty else {
            return
        }

        if selectedRepositories.contains(repository) {
            selectedRepositories.removeAll { $0 == repository }
        } else {
            selectedRepositories.append(repository)
        }

        Task {
            await refresh()
        }
    }

    func addRepository(_ repository: String) {
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidRepository(repository) else {
            return
        }

        availableRepositories = Self.uniqueRepositories(availableRepositories + [repository])
        if !selectedRepositories.contains(repository) {
            selectedRepositories.append(repository)
        }

        Task {
            await refresh()
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    static func isValidRepository(_ repository: String) -> Bool {
        let pieces = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2 else {
            return false
        }
        return pieces.allSatisfy { piece in
            !piece.isEmpty && piece.allSatisfy { character in
                character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
            }
        }
    }

    private static func uniqueRepositories(_ repositories: [String]) -> [String] {
        var seen = Set<String>()
        var uniqueRepositories: [String] = []

        for repository in repositories.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard isValidRepository(repository), seen.insert(repository).inserted else {
                continue
            }
            uniqueRepositories.append(repository)
        }

        return uniqueRepositories
    }
}

enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
final class StatusMenuController: NSObject {
    private let model: ActionsStatusModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var statusAnimationTimer: Timer?
    private var statusAnimationPhase: CGFloat = 0
    private var cancellables: Set<AnyCancellable> = []

    init(model: ActionsStatusModel) {
        self.model = model
        super.init()

        menu.autoenablesItems = false
        statusItem.menu = menu

        if let button = statusItem.button {
            button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
        }

        bindModel()
        rebuild()
    }

    private func bindModel() {
        Publishers.MergeMany([
            model.$availableRepositories.map { _ in () }.eraseToAnyPublisher(),
            model.$selectedRepositories.map { _ in () }.eraseToAnyPublisher(),
            model.$refreshInterval.map { _ in () }.eraseToAnyPublisher(),
            model.$runs.map { _ in () }.eraseToAnyPublisher(),
            model.$runnerSummaries.map { _ in () }.eraseToAnyPublisher(),
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
        updateStatusItem()

        menu.removeAllItems()

        addRepositoryMenu()

        if model.selectedRepositories.isEmpty {
            addInfoRow(title: "No repositories selected", subtitle: "Choose at least one repository", icon: .empty)
            addSeparator()
        } else {
            addBranchStatusRow(model.mainStatus)
            addSeparator()
            addRunSections()

            addSeparator()
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

    private func addBranchStatusRow(_ branchStatus: BranchStatus) {
        addInfoRow(title: branchStatus.title, subtitle: branchStatus.subtitle, icon: .status(branchStatus.statusKind))
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        let statusKind = statusKindForStatusItem
        button.title = ""
        button.image = StatusBarBadgeRenderer.image(for: statusKind, phase: statusAnimationPhase)
        updateStatusAnimationTimer(for: statusKind)
    }

    private var statusKindForStatusItem: StatusKind {
        switch model.state {
        case .loading:
            return .running
        case .failed:
            return .failure
        case .idle where model.runs.isEmpty:
            return .cancelled
        case .idle, .loaded:
            return model.menuStatusKind
        }
    }

    private func updateStatusAnimationTimer(for statusKind: StatusKind) {
        if statusKind.isAnimated {
            guard statusAnimationTimer == nil else {
                return
            }

            let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.statusAnimationPhase = (self.statusAnimationPhase + (1 / 30)).truncatingRemainder(dividingBy: 1)
                    self.statusItem.button?.image = StatusBarBadgeRenderer.image(
                        for: self.statusKindForStatusItem,
                        phase: self.statusAnimationPhase
                    )
                }
            }
            statusAnimationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            statusAnimationTimer?.invalidate()
            statusAnimationTimer = nil
            statusAnimationPhase = 0
        }
    }

    private func addRepositoryMenu() {
        let item = NSMenuItem(title: model.repositoryMenuTitle, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: nil)

        let submenu = NSMenu(title: "Repositories")
        for repository in model.availableRepositories {
            let repositoryItem = NSMenuItem(title: repository, action: #selector(toggleRepository(_:)), keyEquivalent: "")
            repositoryItem.target = self
            repositoryItem.representedObject = repository
            repositoryItem.state = model.selectedRepositories.contains(repository) ? .on : .off
            submenu.addItem(repositoryItem)
        }

        if !model.availableRepositories.isEmpty {
            submenu.addItem(.separator())
        }

        let clipboardRepository = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let addClipboardItem = NSMenuItem(title: "Add Repository from Clipboard", action: #selector(addRepositoryFromClipboard(_:)), keyEquivalent: "")
        addClipboardItem.target = self
        addClipboardItem.isEnabled = ActionsStatusModel.isValidRepository(clipboardRepository) &&
            !model.availableRepositories.contains(clipboardRepository)
        if addClipboardItem.isEnabled {
            addClipboardItem.title = "Add \(clipboardRepository)"
            addClipboardItem.representedObject = clipboardRepository
        }
        submenu.addItem(addClipboardItem)
        addRepositoryEntryItem(to: submenu)

        item.submenu = submenu
        menu.addItem(item)
        addSeparator()
    }

    private func addRepositoryEntryItem(to submenu: NSMenu) {
        let item = NSMenuItem()
        let row = AddRepositoryMenuItemView(existingRepositories: model.availableRepositories) { [weak self] repository in
            self?.menu.cancelTracking()
            self?.model.addRepository(repository)
        }
        row.frame = NSRect(x: 0, y: 0, width: 300, height: 42)
        item.view = row
        submenu.addItem(item)
    }

    private func addRunSections() {
        let sections = RunSections(runs: model.runs)

        if sections.isEmpty {
            addEmptyRunsRow()
            return
        }

        if !sections.unresolvedFailures.isEmpty {
            addSection(title: "Needs Attention", runs: sections.unresolvedFailures, emptyTitle: "No unresolved failures")
            addSeparator()
        }

        addSection(title: "Running or Waiting", runs: sections.activeRuns, emptyTitle: "No active runs") { run in
            .run(run, detail: sections.activeRunDetail(for: run), runnerSummary: model.runnerSummary(for: run))
        }
        addSeparator()
        addSection(title: "Recently Passed", runs: sections.recentPasses, emptyTitle: "No recent passes")
    }

    private func addEmptyRunsRow() {
        switch model.state {
        case .loading:
            addInfoRow(title: "Loading...", subtitle: nil as MenuSubtitle?, icon: .status(.running))
        case .failed(let message):
            addInfoRow(title: "Could not load Actions", subtitle: message, icon: .status(.failure))
        default:
            addInfoRow(title: "No workflow runs", subtitle: nil as MenuSubtitle?, icon: .empty)
        }
    }

    private func addSection(title: String, runs: [WorkflowRun], emptyTitle: String, detail: (WorkflowRun) -> MenuSubtitle? = { .run($0, detail: $0.detail, runnerSummary: nil) }) {
        addHeaderRow(title)

        if runs.isEmpty {
            addInfoRow(title: emptyTitle, subtitle: nil as MenuSubtitle?, icon: .empty)
        } else {
            for run in runs {
                addRunRow(run, detail: detail(run))
            }
        }
    }

    private func addRunRow(_ run: WorkflowRun, detail: MenuSubtitle?) {
        addActionRow(title: run.displayTitle, subtitle: detail, icon: .status(run.statusKind)) { [weak self] in
            self?.model.openRun(run)
        }
    }

    private func addHeaderRow(_ title: String) {
        addCustomItem(title: title.uppercased(), subtitle: nil, icon: .none, isEnabled: false, rowKind: .header, action: nil)
    }

    private func addInfoRow(title: String, subtitle: String?, icon: MenuIcon) {
        addInfoRow(title: title, subtitle: subtitle.map(MenuSubtitle.text), icon: icon)
    }

    private func addInfoRow(title: String, subtitle: MenuSubtitle?, icon: MenuIcon) {
        addCustomItem(title: title, subtitle: subtitle, icon: icon, isEnabled: false, rowKind: .standard, action: nil)
    }

    private func addActionRow(title: String, subtitle: MenuSubtitle? = nil, icon: MenuIcon, isEnabled: Bool = true, action: @escaping () -> Void) {
        addCustomItem(title: title, subtitle: subtitle, icon: icon, isEnabled: isEnabled, rowKind: .standard, action: action)
    }

    private func addCustomItem(title: String, subtitle: MenuSubtitle?, icon: MenuIcon, isEnabled: Bool, rowKind: MenuRowKind, action: (() -> Void)?) {
        let item = NSMenuItem()
        item.isEnabled = isEnabled

        let height: CGFloat = switch rowKind {
        case .header:
            24
        case .standard:
            subtitle?.usesMetadataRow == true ? 62 : (subtitle == nil ? 34 : 48)
        }
        let row = MenuRowView(
            title: title,
            subtitle: subtitle,
            icon: icon,
            isEnabled: isEnabled,
            isInteractive: action != nil,
            rowKind: rowKind,
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

    @objc private func toggleRepository(_ sender: NSMenuItem) {
        guard let repository = sender.representedObject as? String else {
            return
        }
        model.toggleRepository(repository)
    }

    @objc private func addRepositoryFromClipboard(_ sender: NSMenuItem) {
        guard let repository = sender.representedObject as? String else {
            return
        }
        model.addRepository(repository)
    }
}

enum MenuIcon {
    case status(StatusKind)
    case repository
    case refresh
    case power
    case empty
    case none
}

enum MenuRowKind {
    case standard
    case header
}

enum MenuSubtitle {
    case text(String)
    case run(WorkflowRun, detail: String, runnerSummary: RunnerSummary?)

    var detailText: String {
        switch self {
        case .text(let text):
            return text
        case .run(_, let detail, _):
            return detail
        }
    }

    var updatesEverySecond: Bool {
        switch self {
        case .text:
            return false
        case .run(let run, _, _):
            return run.statusKind == .running || run.statusKind == .queued
        }
    }

    func durationText(at date: Date) -> String? {
        switch self {
        case .text:
            return nil
        case .run(let run, _, _):
            return run.durationText(at: date)
        }
    }

    var runnerText: String? {
        switch self {
        case .text:
            return nil
        case .run(_, _, let runnerSummary):
            return runnerSummary?.displayText.nilIfBlank
        }
    }

    var usesMetadataRow: Bool {
        updatesEverySecond
    }
}

struct MenuRowView: View {
    let title: String
    let subtitle: MenuSubtitle?
    let icon: MenuIcon
    let isEnabled: Bool
    let isInteractive: Bool
    let rowKind: MenuRowKind
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            if rowKind == .standard {
                iconView
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(titleFont)
                    .lineLimit(1)
                    .foregroundStyle(titleForegroundStyle)

                if let subtitle {
                    subtitleView(subtitle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(Rectangle())
        .opacity(rowKind == .header || isEnabled ? 1 : 0.5)
        .onHover { hovering in
            isHovered = hovering && isEnabled && isInteractive
        }
        .onTapGesture {
            guard isEnabled, isInteractive else { return }
            action()
        }
    }

    @ViewBuilder
    private func subtitleView(_ subtitle: MenuSubtitle) -> some View {
        if subtitle.updatesEverySecond {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                subtitleContent(subtitle, at: context.date)
            }
        } else {
            subtitleContent(subtitle, at: Date())
        }
    }

    @ViewBuilder
    private func subtitleContent(_ subtitle: MenuSubtitle, at date: Date) -> some View {
        if subtitle.usesMetadataRow {
            VStack(alignment: .leading, spacing: 1) {
                subtitleText(subtitle.detailText)

                HStack(spacing: 6) {
                    if let runnerText = subtitle.runnerText {
                        subtitleMetadataText(runnerText)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }

                    if let durationText = subtitle.durationText(at: date) {
                        subtitleMetadataText(durationText)
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let durationText = subtitle.durationText(at: date) {
            HStack(spacing: 6) {
                subtitleText(subtitle.detailText)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Text(durationText)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            subtitleText(subtitle.detailText)
        }
    }

    private func subtitleText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.secondary)
    }

    private func subtitleMetadataText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .status(let statusKind):
            StatusBadgeView(statusKind: statusKind)
        case .repository:
            Image(systemName: "tray.full")
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
        case .none:
            EmptyView()
        }
    }

    private var titleFont: Font {
        switch rowKind {
        case .standard:
            return .system(size: 14, weight: subtitle == nil ? .regular : .medium)
        case .header:
            return .system(size: 10, weight: .semibold)
        }
    }

    private var titleForegroundStyle: some ShapeStyle {
        switch rowKind {
        case .standard:
            return AnyShapeStyle(Color.primary)
        case .header:
            return AnyShapeStyle(Color.secondary)
        }
    }

    private var verticalPadding: CGFloat {
        switch rowKind {
        case .standard:
            return subtitle == nil ? 7 : 6
        case .header:
            return 5
        }
    }

    private var background: some ShapeStyle {
        isHovered ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Color.clear)
    }

    private var foregroundStyle: some ShapeStyle {
        isHovered ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.primary)
    }
}

struct StatusBadgeView: View {
    let statusKind: StatusKind

    @State private var isAnimating = false

    var body: some View {
        ZStack {
            if statusKind.isAnimated {
                Circle()
                    .stroke(statusKind.color.opacity(isAnimating ? 0 : 0.45), lineWidth: 2)
                    .scaleEffect(isAnimating ? 1.45 : 1)
            }

            Circle()
                .fill(statusKind.color)
                .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
                .shadow(color: statusKind.color.opacity(0.45), radius: 1.5, y: 1)

            Image(systemName: statusKind.badgeSymbolName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(statusKind == .running ? .degrees(isAnimating ? 360 : 0) : .zero)
                .scaleEffect(statusKind == .queued ? (isAnimating ? 1.08 : 0.94) : 1)
        }
        .onAppear {
            guard statusKind.isAnimated else { return }
            isAnimating = true
        }
        .animation(statusKind.animation, value: isAnimating)
    }
}

enum StatusBarBadgeRenderer {
    static func image(for statusKind: StatusKind, phase: CGFloat) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.isTemplate = false

        image.lockFocus()
        defer { image.unlockFocus() }

        let bounds = NSRect(origin: .zero, size: size)
        let badgeRect = bounds.insetBy(dx: 2.5, dy: 2.5)

        if statusKind.isAnimated {
            let pulseProgress = statusKind == .running ? phase : abs(sin(phase * .pi))
            let pulseScale = 1 + (0.28 * pulseProgress)
            let pulseSize = badgeRect.size.width * pulseScale
            let pulseRect = NSRect(
                x: bounds.midX - pulseSize / 2,
                y: bounds.midY - pulseSize / 2,
                width: pulseSize,
                height: pulseSize
            )
            let pulse = NSBezierPath(ovalIn: pulseRect)
            statusKind.nsColor.withAlphaComponent(0.28 * (1 - pulseProgress)).setStroke()
            pulse.lineWidth = 1.5
            pulse.stroke()
        }

        let badge = NSBezierPath(ovalIn: badgeRect)
        statusKind.nsColor.setFill()
        badge.fill()

        NSColor.white.withAlphaComponent(0.65).setStroke()
        badge.lineWidth = 1
        badge.stroke()

        drawSymbol(for: statusKind, in: bounds, phase: phase)

        return image
    }

    private static func drawSymbol(for statusKind: StatusKind, in bounds: NSRect, phase: CGFloat) {
        guard let symbol = NSImage(systemSymbolName: statusKind.badgeSymbolName, accessibilityDescription: nil) else {
            return
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        let configuredSymbol = symbol.withSymbolConfiguration(configuration) ?? symbol
        guard let symbolCopy = configuredSymbol.copy() as? NSImage else {
            return
        }
        symbolCopy.isTemplate = true

        let symbolRect = NSRect(
            x: bounds.midX - 6,
            y: bounds.midY - 6,
            width: 12,
            height: 12
        )

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        if statusKind == .running {
            let transform = NSAffineTransform()
            transform.translateX(by: bounds.midX, yBy: bounds.midY)
            transform.rotate(byDegrees: 360 * phase)
            transform.translateX(by: -bounds.midX, yBy: -bounds.midY)
            transform.concat()
        }

        NSColor.white.set()
        symbolCopy.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

final class AddRepositoryMenuItemView: NSView, NSTextFieldDelegate {
    private let existingRepositories: [String]
    private let addRepository: (String) -> Void
    private let textField = FocusingTextField()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)

    init(existingRepositories: [String], addRepository: @escaping (String) -> Void) {
        self.existingRepositories = existingRepositories
        self.addRepository = addRepository
        super.init(frame: .zero)

        textField.delegate = self
        textField.placeholderString = "owner/repo"
        textField.font = .systemFont(ofSize: 13)
        textField.isBordered = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.focusRingType = .default
        textField.controlSize = .small
        textField.target = self
        textField.action = #selector(addIfValid)
        textField.translatesAutoresizingMaskIntoConstraints = false

        addButton.target = self
        addButton.action = #selector(addIfValid)
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(textField)
        addSubview(addButton)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),
            textField.heightAnchor.constraint(equalToConstant: 24),

            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 54)
        ])

        updateButtonState()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textField)
        super.mouseDown(with: event)
    }

    func controlTextDidChange(_ notification: Notification) {
        updateButtonState()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        addIfValid()
        return true
    }

    @objc private func addIfValid() {
        let repository = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAdd(repository) else {
            NSSound.beep()
            return
        }
        addRepository(repository)
    }

    private func updateButtonState() {
        addButton.isEnabled = canAdd(textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func canAdd(_ repository: String) -> Bool {
        ActionsStatusModel.isValidRepository(repository) &&
            !existingRepositories.contains(repository)
    }
}

final class FocusingTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

struct GitHubActionsClient {
    func fetchRuns(repository: String) async throws -> [WorkflowRun] {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/actions/runs?per_page=50") else {
            throw ClientError.invalidRepository
        }

        let (data, _) = try await fetch(url: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkflowRunsResponse.self, from: data).workflowRuns
    }

    func fetchJobs(repository: String, runID: Int) async throws -> [WorkflowJob] {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/actions/runs/\(runID)/jobs?per_page=100") else {
            throw ClientError.invalidRepository
        }

        let (data, _) = try await fetch(url: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkflowJobsResponse.self, from: data).jobs
    }

    private func fetch(url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CIStatus", forHTTPHeaderField: "User-Agent")

        let token = Self.token()
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(APIError.self, from: data)
            throw ClientError.api(httpResponse.statusCode, apiError?.message, isAuthenticated: token != nil)
        }

        return (data, httpResponse)
    }

    private static func token() -> String? {
        for variableName in ["GITHUB_TOKEN", "GH_TOKEN", "GITHUB_PAT"] {
            if let environmentToken = ProcessInfo.processInfo.environment[variableName]?.nilIfBlank {
                return environmentToken
            }
        }

        return ghToken()
    }

    private static func ghToken() -> String? {
        guard let ghExecutableURL = ghExecutableURL() else {
            return nil
        }

        let process = Process()
        process.executableURL = ghExecutableURL
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
            .nilIfBlank
    }

    private static func ghExecutableURL() -> URL? {
        let candidatePaths = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh"
        ]

        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let searchPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let fallbackSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

        for directory in searchPaths + fallbackSearchPaths {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("gh").path
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }
}

struct WorkflowRunsResponse: Decodable {
    let workflowRuns: [WorkflowRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

struct WorkflowJobsResponse: Decodable {
    let jobs: [WorkflowJob]
}

struct WorkflowJob: Decodable, Identifiable {
    let id: Int
    let name: String
    let status: String
    let runnerName: String?
    let runnerGroupName: String?
    let labels: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case runnerName = "runner_name"
        case runnerGroupName = "runner_group_name"
        case labels
    }

    var isActive: Bool {
        status != "completed"
    }
}

struct RunnerSummary {
    let displayText: String

    init(jobs: [WorkflowJob]) {
        let runnerNames = jobs
            .filter { $0.status == "in_progress" }
            .compactMap { $0.runnerName?.nilIfBlank }
        let uniqueRunnerNames = Self.unique(runnerNames)

        if uniqueRunnerNames.count == 1 {
            displayText = uniqueRunnerNames[0]
        } else if uniqueRunnerNames.count == 2 {
            displayText = uniqueRunnerNames.joined(separator: ", ")
        } else if uniqueRunnerNames.count > 1 {
            displayText = "\(uniqueRunnerNames.count) active runners"
        } else {
            displayText = ""
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var uniqueValues: [String] = []

        for value in values where seen.insert(value).inserted {
            uniqueValues.append(value)
        }

        return uniqueValues
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
    var sourceRepository = ""

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
        let repositoryPrefix = sourceRepository.isEmpty ? "" : "\(sourceRepository) - "
        return "\(repositoryPrefix)\(branch) - \(event) - \(statusText)"
    }

    var menuTitle: String {
        "\(statusKind.symbol) \(name) - \(branch)"
    }

    var displayTitle: String {
        "\(name) - \(branch)"
    }

    var workflowBranchKey: String {
        "\(sourceRepository)\u{1F}\(name)\u{1F}\(branch)"
    }

    func durationText(at date: Date) -> String {
        let endDate = statusKind == .running || statusKind == .queued ? date : updatedAt
        let text = Self.durationFormatter.string(from: max(0, endDate.timeIntervalSince(createdAt))) ?? ""
        return text.nilIfEmpty ?? "0s"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()
}

struct RunSections {
    let unresolvedFailures: [WorkflowRun]
    let activeRuns: [WorkflowRun]
    let recentPasses: [WorkflowRun]
    private let priorCompletedByActiveRunID: [Int: WorkflowRun]

    var isEmpty: Bool {
        unresolvedFailures.isEmpty && activeRuns.isEmpty && recentPasses.isEmpty
    }

    init(runs: [WorkflowRun]) {
        let newestStartedFirst = runs.sorted { $0.createdAt > $1.createdAt }
        let newestCompletedFirst = runs.sorted { $0.updatedAt > $1.updatedAt }
        var newerPassedKeys = Set<String>()
        var includedFailureKeys = Set<String>()
        var includedPassKeys = Set<String>()
        var activeKeys = Set<String>()
        var priorCompletedByActiveRunID: [Int: WorkflowRun] = [:]
        var unresolvedFailures: [WorkflowRun] = []
        var activeRuns: [WorkflowRun] = []
        var recentPasses: [WorkflowRun] = []

        for run in newestStartedFirst where run.statusKind == .running || run.statusKind == .queued {
            activeKeys.insert(run.workflowBranchKey)
            priorCompletedByActiveRunID[run.id] = newestCompletedFirst
                .first { candidate in
                    candidate.workflowBranchKey == run.workflowBranchKey &&
                        candidate.statusKind != .running &&
                        candidate.statusKind != .queued
                }
        }

        for run in newestCompletedFirst {
            switch run.statusKind {
            case .success:
                if includedPassKeys.insert(run.workflowBranchKey).inserted {
                    recentPasses.append(run)
                }
                newerPassedKeys.insert(run.workflowBranchKey)
            case .failure:
                guard !activeKeys.contains(run.workflowBranchKey),
                      !newerPassedKeys.contains(run.workflowBranchKey),
                      includedFailureKeys.insert(run.workflowBranchKey).inserted else {
                    continue
                }
                unresolvedFailures.append(run)
            case .running, .queued:
                continue
            case .cancelled:
                continue
            }
        }

        activeRuns = newestStartedFirst.filter { $0.statusKind == .running || $0.statusKind == .queued }

        self.unresolvedFailures = Array(unresolvedFailures.prefix(5))
        self.activeRuns = activeRuns
        self.recentPasses = Array(recentPasses.prefix(5))
        self.priorCompletedByActiveRunID = priorCompletedByActiveRunID
    }

    func activeRunDetail(for run: WorkflowRun) -> String {
        guard let priorCompletedRun = priorCompletedByActiveRunID[run.id] else {
            return run.detail
        }

        switch priorCompletedRun.statusKind {
        case .failure:
            return "\(run.detail) - previous completed run failed"
        case .success:
            return "\(run.detail) - previous completed run passed"
        case .cancelled:
            return "\(run.detail) - previous completed run stopped"
        case .running, .queued:
            return run.detail
        }
    }
}

struct BranchStatus {
    let branch: String
    let statusKind: StatusKind
    let unresolvedFailureCount: Int
    let activeRunCount: Int
    let recentPassCount: Int

    var title: String {
        branch
    }

    var subtitle: String {
        switch statusKind {
        case .failure:
            return countLabel(unresolvedFailureCount, singular: "unresolved failure", plural: "unresolved failures")
        case .running:
            return countLabel(activeRunCount, singular: "active run", plural: "active runs")
        case .queued:
            return countLabel(activeRunCount, singular: "queued run", plural: "queued runs")
        case .success:
            return recentPassCount == 0 ? "No recent passing runs" : "Passing"
        case .cancelled:
            return "No recent runs"
        }
    }

    init(branch: String, runs: [WorkflowRun]) {
        self.branch = branch

        let branchRuns = runs
            .filter { $0.branch == branch }
            .sorted { $0.createdAt > $1.createdAt }

        var activeKeys = Set<String>()
        var resolvedKeys = Set<String>()
        var unresolvedFailureKeys = Set<String>()
        var passKeys = Set<String>()
        var activeRunCount = 0
        var hasRunningRun = false

        for run in branchRuns where run.statusKind == .running || run.statusKind == .queued {
            activeKeys.insert(run.workflowBranchKey)
            activeRunCount += 1
            hasRunningRun = hasRunningRun || run.statusKind == .running
        }

        for run in branchRuns {
            switch run.statusKind {
            case .success:
                resolvedKeys.insert(run.workflowBranchKey)
                passKeys.insert(run.workflowBranchKey)
            case .failure:
                guard !activeKeys.contains(run.workflowBranchKey),
                      !resolvedKeys.contains(run.workflowBranchKey) else {
                    continue
                }
                unresolvedFailureKeys.insert(run.workflowBranchKey)
            case .running, .queued, .cancelled:
                continue
            }
        }

        unresolvedFailureCount = unresolvedFailureKeys.count
        self.activeRunCount = activeRunCount
        recentPassCount = passKeys.count

        if unresolvedFailureCount > 0 {
            statusKind = .failure
        } else if hasRunningRun {
            statusKind = .running
        } else if activeRunCount > 0 {
            statusKind = .queued
        } else if recentPassCount > 0 {
            statusKind = .success
        } else {
            statusKind = .cancelled
        }
    }

    private func countLabel(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
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

    var compactStatus: String {
        switch self {
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
        "\(symbol) \(compactStatus)"
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

    var nsColor: NSColor {
        switch self {
        case .success:
            return .systemGreen
        case .failure:
            return .systemRed
        case .running:
            return .systemBlue
        case .queued:
            return .systemOrange
        case .cancelled:
            return .systemGray
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

    var isAnimated: Bool {
        self == .running || self == .queued
    }

    var animation: Animation? {
        switch self {
        case .running:
            return .linear(duration: 1.1).repeatForever(autoreverses: false)
        case .queued:
            return .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
        case .success, .failure, .cancelled:
            return nil
        }
    }
}

struct APIError: Decodable {
    let message: String
}

enum ClientError: LocalizedError {
    case invalidRepository
    case invalidResponse
    case api(Int, String?, isAuthenticated: Bool)

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "Repository must be in owner/repo format."
        case .invalidResponse:
            return "GitHub returned an unreadable response."
        case .api(let statusCode, let message, let isAuthenticated):
            if statusCode == 404 && !isAuthenticated {
                return "GitHub returned 404. For private repos, set GITHUB_TOKEN/GH_TOKEN or run gh auth login."
            }
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

    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
