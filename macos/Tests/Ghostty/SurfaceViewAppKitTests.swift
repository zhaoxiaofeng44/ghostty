@testable import Ghostty
import Testing
import Darwin.POSIX

struct SurfaceViewAppKitTests {
    @Test(arguments: [
        // Valid: plain ssh invocations reported by `ghostty +ssh`.
        ("ssh example.com", true),
        ("ssh user@example.com", true),
        ("ssh -p 2222 user@example.com", true),
        ("ssh -o Foo=bar 'my host'", true),
        // Invalid: not an ssh command.
        ("", false),
        ("ssh", false),
        ("ls -la", false),
        ("rm -rf /", false),
        // Invalid: control characters would be replayed into a shell.
        ("ssh example.com\nrm -rf /", false),
        ("ssh example.com\u{0008}", false),
        ("ssh example.com\u{007F}", false),
    ])
    func validatesRestoreCommand(command: String, expected: Bool) {
        #expect(
            Ghostty.SurfaceView.validRestoreCommand(command) == expected
        )
    }

    @Test func rejectsOverlyLongRestoreCommand() {
        let command = "ssh " + String(repeating: "a", count: 4097)
        #expect(Ghostty.SurfaceView.validRestoreCommand(command) == false)
    }

    @Test func acceptsMaximumLengthRestoreCommand() {
        // 4 characters for "ssh " plus 4092 argument characters.
        let command = "ssh " + String(repeating: "a", count: 4092)
        #expect(Ghostty.SurfaceView.validRestoreCommand(command) == true)
    }

    @Test(arguments: [
        ("\u{0008}", true),
        ("\u{001F}", true),
        ("\u{007F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{0009}x", false),
        ("\u{0009}\u{0009}", false),
    ])
    func suppressesOnlySingleC0ControlTextWhileComposing(
        text: String,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                text,
                composing: true
            ) == expected
        )
    }

    @Test func doesNotSuppressControlTextWhenNotComposing() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                "\u{0008}",
                composing: false
            ) == false
        )
    }

    @Test func recordsRecentWorkingDirectoriesNewestFirst() {
        var history: [String] = []
        history = Ghostty.OSSurfaceView.updatedRecentWorkingDirectories(history, recording: "/a")
        history = Ghostty.OSSurfaceView.updatedRecentWorkingDirectories(history, recording: "/b")
        history = Ghostty.OSSurfaceView.updatedRecentWorkingDirectories(history, recording: "/c")
        history = Ghostty.OSSurfaceView.updatedRecentWorkingDirectories(history, recording: "/a")
        #expect(history == ["/a", "/c", "/b"])
    }

    @Test func processWorkingDirectoryReadsCurrentProcess() {
        let path = Ghostty.OSSurfaceView.processWorkingDirectory(pid: getpid())
        #expect(path == FileManager.default.currentDirectoryPath)
    }

    @Test func capsRecentWorkingDirectories() {
        var history: [String] = []
        for index in 0..<12 {
            history = Ghostty.OSSurfaceView.updatedRecentWorkingDirectories(
                history,
                recording: "/dir-\(index)")
        }
        #expect(history.count == Ghostty.OSSurfaceView.recentWorkingDirectoryLimit)
        #expect(history.first == "/dir-11")
        #expect(history.last == "/dir-2")
    }

    @Test func doesNotSuppressMissingText() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                nil,
                composing: true
            ) == false
        )
    }
}
