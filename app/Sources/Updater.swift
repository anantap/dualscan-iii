import AppKit
import Foundation
import Observation

/// Keeps the app up to date from the repository's GitHub releases, like Roll Converter. Every push
/// to `main` of its own repository builds the app and publishes it as the latest release, tagged `build-<number>`. The app looks for a
/// newer one at launch, downloads it in the background, and puts it in place when you restart (or quit).
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, downloading(Int), upToDate
        /// A newer build is downloaded and ready to put in place.
        case ready(Int)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The fixes in the downloaded build(s), newest first, for the update popup.
    private(set) var notes: [String] = []
    /// The update popup is open.
    var promptShown = false

    static let repository = Edition.repository
    static let assetName = Edition.releaseAsset
    static let appName = "\(Edition.name).app"

    let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    private var staged: URL?

    /// A build you chose to skip: the popup doesn't come back for it (only for a newer one).
    private var skippedBuild: Int {
        get { UserDefaults.standard.integer(forKey: "skippedBuild") }
        set { UserDefaults.standard.set(newValue, forKey: "skippedBuild") }
    }

    /// Looks once, at launch. Not in the self-test or a local build (build 1).
    func start() {
        guard SelfTest.outputDir == nil, currentBuild > 1 else { return }
        check()
    }

    // MARK: - Checking and downloading

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        var build: Int? {
            tag_name.hasPrefix(Edition.releaseTagPrefix) ? Int(tag_name.dropFirst(Edition.releaseTagPrefix.count)) : nil
        }
    }

    /// Looks for a newer build. Started from the menu (`userInitiated`), it always shows the popup
    /// (even for a skipped build) or says there's nothing new; in the background it stays quiet and
    /// leaves a skipped build alone.
    func check(userInitiated: Bool = false) {
        switch state {
        case .checking, .downloading:
            return
        case .ready:
            if userInitiated { promptShown = true }
            return
        default: break
        }
        state = .checking
        Task {
            do {
                let latest = try await Self.newerReleases(than: currentBuild)
                guard let latest, userInitiated || latest.build > skippedBuild else {
                    state = .upToDate
                    if userInitiated {
                        alert("\(Edition.name) is up to date", "You have build \(currentBuild), the newest there is.")
                    }
                    return
                }
                state = .downloading(latest.build)
                staged = try await Self.download(latest.url, build: latest.build)
                notes = latest.notes
                state = .ready(latest.build)
                promptShown = true
            } catch {
                state = .failed(error.localizedDescription)
                if userInitiated {
                    alert("Couldn't check for updates", error.localizedDescription)
                }
            }
        }
    }

    /// Popup: don't put this build in place, and don't ask about it again.
    func skip() {
        guard case .ready(let build) = state else { return }
        skippedBuild = build
        staged = nil
        state = .idle
        promptShown = false
    }

    /// Popup: it goes in place when you quit.
    func later() { promptShown = false }

    private func alert(_ title: String, _ text: String) {
        let panel = NSAlert()
        panel.messageText = title
        panel.informativeText = text
        panel.runModal()
    }

    /// The newest build after `current`, with the fixes of every build in between.
    private static func newerReleases(than current: Int) async throws -> (build: Int, url: URL, notes: [String])? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DualScanIII", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        let newer = try JSONDecoder().decode([Release].self, from: data)
            .filter { !$0.draft && !$0.prerelease && ($0.build ?? 0) > current }
            .sorted { $0.build! > $1.build! }
        guard let latest = newer.first, let build = latest.build,
              let asset = latest.assets.first(where: { $0.name == assetName }) else { return nil }
        var notes: [String] = []
        for release in newer {
            for line in (release.body ?? "").split(whereSeparator: \.isNewline) {
                var note = line.trimmingCharacters(in: .whitespaces)
                if note.hasPrefix("- ") { note.removeFirst(2) }
                if !note.isEmpty, !notes.contains(note) { notes.append(note) }
            }
        }
        return (build, asset.browser_download_url, notes)
    }

    /// Downloads and unpacks the build; returns the new app, checked to be that build.
    private static func download(_ url: URL, build: Int) async throws -> URL {
        let (file, _) = try await URLSession.shared.download(from: url)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DualScanUpdate-\(build)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", file.path, folder.path])
        try? FileManager.default.removeItem(at: file)
        let app = folder.appendingPathComponent(appName)
        guard let bundle = Bundle(url: app),
              Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") == build else {
            throw Failure(message: "The downloaded update isn't build \(build)")
        }
        return app
    }

    /// Only the self-test sets the state by hand, to take pictures of the update card.
    func showForSelfTest(_ state: State, notes: [String] = []) {
        guard SelfTest.outputDir != nil else { return }
        self.state = state
        self.notes = notes
    }

    // MARK: - Installing

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Why the app can't replace itself where it is, if it can't.
    var installProblem: String? {
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") {
            return "Move \(Edition.name) to your Applications folder to update it."
        }
        if !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            return "\(Edition.name) can't update itself in \(app.deletingLastPathComponent().lastPathComponent)."
        }
        return nil
    }

    /// Puts the downloaded build in place once this app has quit, then opens it if `relaunch`.
    func install(relaunch: Bool) {
        guard let staged, installProblem == nil else { return }
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        old="$2"; new="$3"; aside="$4"
        if mv "$old" "$aside"; then
          if mv "$new" "$old"; then rm -rf "$aside"; else mv "$aside" "$old"; fi
        fi
        xattr -dr com.apple.quarantine "$old" 2>/dev/null
        if [ "$5" = 1 ]; then open "$old"; fi
        """
        let app = Bundle.main.bundleURL
        let aside = staged.deletingLastPathComponent().appendingPathComponent("previous.app")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                             app.path, staged.path, aside.path, relaunch ? "1" : "0"]
        do {
            try process.run()
            self.staged = nil
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func restartNow() {
        guard staged != nil, installProblem == nil else { return }
        install(relaunch: true)
        // The app won't quit while the popup (a sheet) is open: close it first, then quit.
        promptShown = false
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            NSApp.terminate(nil)
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(message: "Could not unpack the update") }
    }
}
