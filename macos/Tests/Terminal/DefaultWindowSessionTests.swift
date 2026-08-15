import Testing
import Foundation
@testable import Ghostty

@Suite
struct DefaultWindowSessionTests {
    @MainActor
    @Test
    func snapshotFromEmptyControllersIsNil() {
        #expect(DefaultWindowSession.snapshot(from: []) == nil)
    }

    @Test
    func encodeDecodePreservesTabsAndHistory() throws {
        let leftID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let rightID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let session = DefaultWindowSession(
            version: DefaultWindowSession.currentVersion,
            selectedTabIndex: 1,
            tabs: [
                .init(
                    frame: CGRect(x: 10, y: 20, width: 800, height: 600),
                    focusedSurfaceID: leftID,
                    titleOverride: "main",
                    tabColor: .green,
                    effectiveFullscreenMode: .native,
                    surfaceTree: .split(.init(
                        direction: .horizontal,
                        ratio: 0.4,
                        left: .leaf(.init(
                            id: leftID,
                            pwd: "/tmp/left",
                            title: "left",
                            isUserSetTitle: true,
                            restoreCommand: "ssh example.com",
                            recentWorkingDirectories: ["/tmp/left", "/tmp"])),
                        right: .leaf(.init(
                            id: rightID,
                            pwd: "/tmp/right",
                            title: "right",
                            isUserSetTitle: false,
                            restoreCommand: nil,
                            recentWorkingDirectories: ["/tmp/right"])))),
                    zoomedLeafID: leftID),
                .init(
                    frame: CGRect(x: 40, y: 50, width: 640, height: 480),
                    focusedSurfaceID: rightID,
                    titleOverride: nil,
                    tabColor: nil,
                    effectiveFullscreenMode: nil,
                    surfaceTree: .leaf(.init(
                        id: rightID,
                        pwd: "/Users/me",
                        title: nil,
                        isUserSetTitle: false,
                        restoreCommand: nil,
                        recentWorkingDirectories: ["/Users/me", "/Users"])),
                    zoomedLeafID: nil),
            ])

        let data = try PropertyListEncoder().encode(session)
        let decoded = try PropertyListDecoder().decode(DefaultWindowSession.self, from: data)
        #expect(decoded == session)
        #expect(decoded.selectedTabIndex == 1)
        #expect(decoded.tabs.count == 2)
        #expect(decoded.tabs[0].focusedSurfaceID == leftID)
        if case .split(let split) = decoded.tabs[0].surfaceTree {
            #expect(split.ratio == 0.4)
            if case .leaf(let left) = split.left {
                #expect(left.pwd == "/tmp/left")
                #expect(left.recentWorkingDirectories == ["/tmp/left", "/tmp"])
            } else {
                Issue.record("expected left leaf")
            }
        } else {
            Issue.record("expected split tree")
        }
    }

    @Test
    func persistIgnoresEmptySnapshots() {
        let suiteName = "DefaultWindowSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = DefaultWindowSessionStore(
            defaults: defaults,
            windowSaveState: { "always" })
        let existing = Data("keep-me".utf8)
        defaults.set(existing, forKey: DefaultWindowSessionStore.defaultsKey)

        store.persist(nil)
        store.persist(DefaultWindowSession(
            version: DefaultWindowSession.currentVersion,
            selectedTabIndex: 0,
            tabs: []))

        #expect(defaults.data(forKey: DefaultWindowSessionStore.defaultsKey) == existing)
    }

    @Test
    func neverWindowSaveStateSkipsLoadAndSave() {
        let suiteName = "DefaultWindowSessionNever.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = DefaultWindowSession(
            version: DefaultWindowSession.currentVersion,
            selectedTabIndex: 0,
            tabs: [
                .init(
                    frame: .zero,
                    focusedSurfaceID: nil,
                    titleOverride: nil,
                    tabColor: nil,
                    effectiveFullscreenMode: nil,
                    surfaceTree: .leaf(.init(
                        id: UUID(),
                        pwd: "/tmp",
                        title: nil,
                        isUserSetTitle: false,
                        restoreCommand: nil,
                        recentWorkingDirectories: [])),
                    zoomedLeafID: nil),
            ])
        let encoded = try! PropertyListEncoder().encode(session)
        defaults.set(encoded, forKey: DefaultWindowSessionStore.defaultsKey)

        let neverStore = DefaultWindowSessionStore(
            defaults: defaults,
            windowSaveState: { "never" })
        #expect(neverStore.load() == nil)

        neverStore.persist(session)
        #expect(defaults.data(forKey: DefaultWindowSessionStore.defaultsKey) == encoded)
    }
}
