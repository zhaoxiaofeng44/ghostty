import AppKit
import GhosttyKit

enum DefaultWindowSessionRole {
    case persistent
    case temporary
}

struct DefaultWindowSession: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var selectedTabIndex: Int
    var tabs: [Tab]

    struct Tab: Codable, Equatable {
        var frame: CGRect
        var focusedSurfaceID: UUID?
        var titleOverride: String?
        var tabColor: TerminalTabColor?
        var effectiveFullscreenMode: FullscreenMode?
        var surfaceTree: Node
        var zoomedLeafID: UUID?

        indirect enum Node: Codable, Equatable {
            case leaf(Leaf)
            case split(Split)
        }

        struct Leaf: Codable, Equatable {
            var id: UUID
            var pwd: String?
            var title: String?
            var isUserSetTitle: Bool
            var restoreCommand: String?
            var recentWorkingDirectories: [String]
        }

        struct Split: Codable, Equatable {
            var direction: SplitTree<Ghostty.SurfaceView>.Direction
            var ratio: Double
            var left: Node
            var right: Node
        }
    }
}

extension DefaultWindowSession {
    @MainActor
    static func snapshot(from controllers: [TerminalController]) -> DefaultWindowSession? {
        let tabs = controllers.compactMap(Tab.init(controller:))
        guard !tabs.isEmpty else { return nil }

        let selectedTabIndex: Int
        if let selected = controllers.firstIndex(where: { $0.window?.isKeyWindow == true }) {
            selectedTabIndex = selected
        } else if let seed = TerminalController.persistentSeed,
                  let index = controllers.firstIndex(where: { $0 === seed }) {
            selectedTabIndex = index
        } else {
            selectedTabIndex = 0
        }

        return .init(
            version: currentVersion,
            selectedTabIndex: selectedTabIndex,
            tabs: tabs)
    }
}

extension DefaultWindowSession.Tab {
    @MainActor
    init?(controller: TerminalController) {
        guard let window = controller.window else { return nil }
        guard let root = controller.surfaceTree.root else { return nil }
        self.init(
            frame: window.frame,
            focusedSurfaceID: controller.focusedSurface?.id,
            titleOverride: controller.titleOverride,
            tabColor: (window as? TerminalWindow)?.tabColor,
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            surfaceTree: .init(node: root),
            zoomedLeafID: controller.surfaceTree.zoomed?.leftmostLeaf().id)
    }

    func makeSurfaceTree(app: ghostty_app_t) -> SplitTree<Ghostty.SurfaceView> {
        let root = surfaceTree.makeSplitNode(app: app)
        let zoomed: SplitTree<Ghostty.SurfaceView>.Node?
        if let zoomedLeafID {
            zoomed = root.find(id: zoomedLeafID)
        } else {
            zoomed = nil
        }
        return SplitTree(root: root, zoomed: zoomed)
    }
}

private extension DefaultWindowSession.Tab.Node {
    @MainActor
    init(node: SplitTree<Ghostty.SurfaceView>.Node) {
        switch node {
        case .leaf(let view):
            let processPwd = view.surfaceModel?.foregroundPID.flatMap {
                Ghostty.OSSurfaceView.processWorkingDirectory(pid: pid_t($0))
            }
            if let processPwd {
                view.recordWorkingDirectory(processPwd)
            }
            self = .leaf(.init(
                id: view.id,
                pwd: view.pwd ?? processPwd,
                title: view.title,
                isUserSetTitle: view.isUserSetTitle,
                restoreCommand: view.restoreCommand,
                recentWorkingDirectories: view.recentWorkingDirectories))

        case .split(let split):
            self = .split(.init(
                direction: split.direction,
                ratio: split.ratio,
                left: .init(node: split.left),
                right: .init(node: split.right)))
        }
    }

    func makeSplitNode(app: ghostty_app_t) -> SplitTree<Ghostty.SurfaceView>.Node {
        switch self {
        case .leaf(let leaf):
            return .leaf(view: leaf.makeSurfaceView(app: app))

        case .split(let split):
            return .split(.init(
                direction: split.direction,
                ratio: split.ratio,
                left: split.left.makeSplitNode(app: app),
                right: split.right.makeSplitNode(app: app)))
        }
    }
}

private extension DefaultWindowSession.Tab.Leaf {
    func makeSurfaceView(app: ghostty_app_t) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = pwd
        if let restoreCommand, Ghostty.SurfaceView.validRestoreCommand(restoreCommand) {
            config.initialInput = restoreCommand + "\n"
        }

        let view = Ghostty.SurfaceView(app, baseConfig: config, uuid: id)
        view.applyRestoredSession(
            title: title,
            isUserSetTitle: isUserSetTitle,
            recentWorkingDirectories: recentWorkingDirectories)
        return view
    }
}

final class DefaultWindowSessionStore {
    static let shared = DefaultWindowSessionStore()
    static let defaultsKey = "DefaultWindowSession"

    private let defaults: UserDefaults
    private let windowSaveState: () -> String
    private var pwdSaveWorkItem: DispatchWorkItem?
    private let pwdDebounce: TimeInterval

    init(
        defaults: UserDefaults = .ghostty,
        windowSaveState: @escaping () -> String = {
            (NSApp.delegate as? AppDelegate)?.ghostty.config.windowSaveState ?? ""
        },
        pwdDebounce: TimeInterval = 0.75
    ) {
        self.defaults = defaults
        self.windowSaveState = windowSaveState
        self.pwdDebounce = pwdDebounce
    }

    @MainActor
    func saveImmediately() {
        pwdSaveWorkItem?.cancel()
        pwdSaveWorkItem = nil
        persist(DefaultWindowSession.snapshot(from: TerminalController.persistentControllers))
    }

    @MainActor
    func schedulePwdSave() {
        pwdSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.saveImmediately()
            }
        }
        pwdSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pwdDebounce, execute: work)
    }

    @MainActor
    func flush() {
        pwdSaveWorkItem?.cancel()
        pwdSaveWorkItem = nil
        persist(DefaultWindowSession.snapshot(from: TerminalController.persistentControllers))
    }

    func persist(_ session: DefaultWindowSession?) {
        guard windowSaveState() != "never" else { return }
        guard let session, !session.tabs.isEmpty else { return }
        do {
            defaults.set(try PropertyListEncoder().encode(session), forKey: Self.defaultsKey)
        } catch {
            AppDelegate.logger.error("failed to persist default window session: \(error.localizedDescription, privacy: .public)")
        }
    }

    func load() -> DefaultWindowSession? {
        guard windowSaveState() != "never" else { return nil }
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return nil }
        do {
            let session = try PropertyListDecoder().decode(DefaultWindowSession.self, from: data)
            guard session.version == DefaultWindowSession.currentVersion, !session.tabs.isEmpty else {
                return nil
            }
            return session
        } catch {
            AppDelegate.logger.error("failed to load default window session: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
