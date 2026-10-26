import AppIntents
import BerthKit

// MARK: Entities

struct ShareEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Share")
    static let defaultQuery = ShareQuery()

    var id: UUID
    var name: String
    var location: String
    var symbol: String

    init(_ share: Share) {
        id = share.id
        name = share.name
        location = share.locationSummary
        symbol = share.icon.symbol
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(location)", image: .init(systemName: symbol))
    }
}

struct ShareQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ShareEntity] {
        identifiers.compactMap { AppModel.shared.config.share(id: $0) }.map(ShareEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ShareEntity] {
        AppModel.shared.config.shares
            .filter { $0.name.localizedStandardContains(string) || $0.shareName.localizedStandardContains(string) }
            .map(ShareEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ShareEntity] {
        AppModel.shared.config.shares.map(ShareEntity.init)
    }
}

struct ShareGroupEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Share Group")
    static let defaultQuery = ShareGroupQuery()

    var id: UUID
    var name: String
    var symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }
}

struct ShareGroupQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ShareGroupEntity] {
        AppModel.shared.config.groups.filter { identifiers.contains($0.id) }.map { ShareGroupEntity(id: $0.id, name: $0.name, symbol: $0.symbol) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ShareGroupEntity] {
        AppModel.shared.config.groups.map { ShareGroupEntity(id: $0.id, name: $0.name, symbol: $0.symbol) }
    }
}

enum BerthIntentError: Error, CustomLocalizedStringResourceConvertible {
    case shareMissing
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .shareMissing: "That share no longer exists in Berth."
        case .failed(let message): "\(message)"
        }
    }
}

// MARK: Intents

struct MountShareIntent: AppIntent {
    static let title: LocalizedStringResource = "Mount Share"
    static let description = IntentDescription("Mounts an SMB share configured in Berth and waits until it’s ready.")

    @Parameter(title: "Share") var share: ShareEntity

    static var parameterSummary: some ParameterSummary { Summary("Mount \(\.$share)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = AppModel.shared
        guard model.config.share(id: share.id) != nil else { throw BerthIntentError.shareMissing }
        model.coordinator.mount(share.id)
        let rt = model.runtime(share.id)
        let deadline = ContinuousClock.now + .seconds(60)
        try? await Task.sleep(for: .milliseconds(150))
        while ContinuousClock.now < deadline {
            switch rt.state {
            case .mounted:
                let path = rt.mountPoint ?? ""
                return .result(value: path, dialog: "\(share.name) is mounted.")
            case .authFailed, .failed, .tailscaleDown, .paused:
                throw BerthIntentError.failed("\(share.name): \(rt.lastError ?? rt.state.title)")
            case .hostUnreachable where rt.nextRetryAt != nil:
                throw BerthIntentError.failed("\(share.name): \(rt.lastError ?? rt.state.title)")
            default:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        throw BerthIntentError.failed("\(share.name) is still \(rt.state.title.lowercased()).")
    }
}

struct UnmountShareIntent: AppIntent {
    static let title: LocalizedStringResource = "Unmount Share"
    static let description = IntentDescription("Unmounts an SMB share.")

    @Parameter(title: "Share") var share: ShareEntity
    @Parameter(title: "Force", description: "Unmount even if files are open.", default: false) var force: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Unmount \(\.$share)") { \.$force }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await AppModel.shared.coordinator.unmount(share.id, force: force) {
        case .unmounted, .notMounted: return .result(dialog: "\(share.name) is unmounted.")
        case .busy(let message): throw BerthIntentError.failed("\(share.name) is in use: \(message)")
        case .failed(let message): throw BerthIntentError.failed(message)
        }
    }
}

struct MountAllSharesIntent: AppIntent {
    static let title: LocalizedStringResource = "Mount All Shares"
    static let description = IntentDescription("Mounts every share, or every share in a group.")

    @Parameter(title: "Group") var group: ShareGroupEntity?

    static var parameterSummary: some ParameterSummary { Summary("Mount all shares in \(\.$group)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.coordinator.mountAll(groupID: group?.id, onlyGroup: group != nil)
        return .result()
    }
}

struct UnmountAllSharesIntent: AppIntent {
    static let title: LocalizedStringResource = "Unmount All Shares"
    static let description = IntentDescription("Unmounts every share, or every share in a group.")

    @Parameter(title: "Group") var group: ShareGroupEntity?
    @Parameter(title: "Force", default: false) var force: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Unmount all shares in \(\.$group)") { \.$force }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppModel.shared.coordinator.unmountAll(groupID: group?.id, onlyGroup: group != nil, force: force)
        return .result()
    }
}

struct GetShareStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Share Status"
    static let description = IntentDescription("Returns whether a share is mounted, its state and mount point.")

    @Parameter(title: "Share") var share: ShareEntity

    static var parameterSummary: some ParameterSummary { Summary("Get the status of \(\.$share)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let rt = AppModel.shared.runtime(share.id)
        let detail = rt.mountPoint.map { " at \($0)" } ?? ""
        return .result(value: rt.state.isMounted, dialog: "\(share.name): \(rt.state.title)\(detail)")
    }
}

struct BerthShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: MountShareIntent(),
            phrases: ["Mount \(\.$share) with \(.applicationName)", "Connect to \(\.$share) in \(.applicationName)"],
            shortTitle: "Mount Share",
            systemImageName: "externaldrive.badge.plus"
        )
        AppShortcut(
            intent: MountAllSharesIntent(),
            phrases: ["Mount all shares with \(.applicationName)", "Mount everything in \(.applicationName)"],
            shortTitle: "Mount All",
            systemImageName: "externaldrive.connected.to.line.below"
        )
        AppShortcut(
            intent: UnmountAllSharesIntent(),
            phrases: ["Unmount all shares with \(.applicationName)", "Eject everything in \(.applicationName)"],
            shortTitle: "Unmount All",
            systemImageName: "eject"
        )
    }
}
