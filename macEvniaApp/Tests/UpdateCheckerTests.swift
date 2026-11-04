import AppKit
import Foundation

private final class ReleaseProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var response: Result<(Int, Data), Error> = .success((200, Data()))
    private static var requests: [URLRequest] = []

    static func respond(with result: Result<(Int, Data), Error>) {
        lock.lock()
        response = result
        lock.unlock()
    }

    static var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let result = Self.response
        Self.lock.unlock()
        switch result {
        case .success(let (code, data)):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@main
enum UpdateCheckerTests {
    static func release(_ version: String, draft: Bool = false, prerelease: Bool = false) -> GitHubRelease {
        GitHubRelease(tagName: version, pageURL: URL(string: "https://github.com/funk4d/macEvnia/releases/tag/\(version)")!, draft: draft, prerelease: prerelease)
    }

    static func check(_ checker: UpdateChecker, force: Bool = true) -> Result<AvailableUpdate?, Error> {
        var result: Result<AvailableUpdate?, Error>?
        checker.check(force: force) { outcome in
            precondition(Thread.isMainThread, "Update observers must run on the main thread")
            result = outcome
        }
        let deadline = Date().addingTimeInterval(25)
        while result == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard let result else { fatalError("Update check did not complete") }
        return result
    }

    static func main() throws {
        _ = NSApplication.shared
        precondition(ReleaseVersion("v0.3.2") == ReleaseVersion("0.3.2"))
        precondition(ReleaseVersion("0.3") == ReleaseVersion("0.3.0"))
        precondition(ReleaseVersion("0.4") == ReleaseVersion("0.4.0"))
        precondition(ReleaseVersion("0.4")! > ReleaseVersion("0.3.2")!)
        precondition(ReleaseVersion("0.3.10")! > ReleaseVersion("0.3.9")!)
        precondition(ReleaseVersion("1.0.0")! > ReleaseVersion("0.99.99")!)
        for invalid in ["", "v", "0..3", "0.4.0-rc.1", "main", "0.3.2.zip", "-1.0.0", "0.3.2.1", "999999999999999999999999"] {
            precondition(ReleaseVersion(invalid) == nil, "Invalid version accepted: \(invalid)")
        }
        for candidate in [release("0.3.2"), release("0.3.1"), release("0.4.0", draft: true), release("0.4.0-rc.1", prerelease: true)] {
            let update = try AvailableUpdate.newerRelease(candidate, than: "0.3.2")
            precondition(update == nil)
        }
        for unsafe in ["http://github.com/funk4d/macEvnia/releases/tag/0.4.0", "https://github.com.evil.test/funk4d/macEvnia/releases/tag/0.4.0",
                       "https://github.com/someone/another/releases/tag/0.4.0", "https://user@github.com/funk4d/macEvnia/releases/tag/0.4.0",
                       "https://github.com/funk4d/macEvnia/releases/tag/"] {
            let candidate = GitHubRelease(tagName: "0.4.0", pageURL: URL(string: unsafe)!, draft: false, prerelease: false)
            do {
                _ = try AvailableUpdate.newerRelease(candidate, than: "0.3.2")
                fatalError("Untrusted release URL accepted: \(unsafe)")
            } catch UpdateCheckError.invalidReleaseURL {}
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let suite = "local.macevnia.update-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(installedVersion: "0.3.2", session: session, defaults: defaults)
        var observerCalls = 0
        checker.onChange = { precondition(Thread.isMainThread); observerCalls += 1 }

        ReleaseProtocol.respond(with: .success((200, try JSONEncoder().encode(release("v0.4.0")))))
        let first = try check(checker).get()
        precondition(first?.version == ReleaseVersion("0.4.0"))
        precondition(checker.availableUpdate == first && !checker.isChecking)
        let request = ReleaseProtocol.recordedRequests.last!
        precondition(request.url == UpdateChecker.latestReleaseURL)
        precondition(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)

        let beforeConcurrent = ReleaseProtocol.recordedRequests.count
        var completed = 0
        checker.check(force: true) { result in
            precondition((try? result.get()) == first)
            completed += 1
        }
        checker.check(force: true) { result in
            precondition((try? result.get()) == first)
            completed += 1
        }
        let concurrentDeadline = Date().addingTimeInterval(5)
        while completed < 2 && Date() < concurrentDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(completed == 2 && ReleaseProtocol.recordedRequests.count == beforeConcurrent + 1,
                     "Concurrent checks must share one request")

        let count = ReleaseProtocol.recordedRequests.count
        let cached = try check(checker, force: false).get()
        precondition(cached == first)
        precondition(ReleaseProtocol.recordedRequests.count == count, "Repeated menu opens must not poll GitHub")
        checker.skipAvailableUpdate()
        precondition(checker.availableUpdate == nil && checker.latestUpdate == first)
        let reloaded = UpdateChecker(installedVersion: "0.3.2", session: session, defaults: defaults)
        precondition(reloaded.availableUpdate == nil && reloaded.latestUpdate == first, "Skip must survive restart")

        ReleaseProtocol.respond(with: .success((200, try JSONEncoder().encode(release("0.4.1")))))
        let newer = try check(checker).get()
        precondition(newer?.version == ReleaseVersion("0.4.1") && checker.availableUpdate == newer, "Skip must not hide future releases")
        let upgraded = UpdateChecker(installedVersion: "0.4.1", session: session, defaults: defaults)
        precondition(upgraded.availableUpdate == nil, "An installed update must remove the badge")

        for response: Result<(Int, Data), Error> in [.success((403, Data())), .success((200, Data("not json".utf8))), .failure(URLError(.notConnectedToInternet))] {
            ReleaseProtocol.respond(with: response)
            switch check(checker) {
            case .success: fatalError("Network or API errors must be reported")
            case .failure: break
            }
            precondition(checker.availableUpdate == newer, "Offline checks must retain a known update")
        }
        ReleaseProtocol.respond(with: .success((200, try JSONEncoder().encode(release("0.3.2")))))
        let upToDate = try check(checker).get()
        precondition(upToDate == nil && checker.availableUpdate == nil)
        precondition(observerCalls >= 10)
        print("PASS: version comparison, stable releases, trusted URLs, HTTP requests, throttling, Skip, persistence, offline and API errors")

        try testMenuIcons()
        if CommandLine.arguments.contains("--live") {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil) as! [String: Any]
            let version = plist["CFBundleShortVersionString"] as! String
            let live = UpdateChecker(installedVersion: version, defaults: nil)
            let result = try check(live).get()
            print("LIVE PASS: " + (result.map { "GitHub offers macEvnia \($0.version): \($0.pageURL)" } ?? "No stable GitHub release is newer than installed macEvnia \(version)"))
        }
    }

    private static func testMenuIcons() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for name in ["menubar-light", "menubar-dark", "menubar-update-light", "menubar-update-dark"] {
            let source = NSImage(contentsOf: root.appendingPathComponent("icons/\(name).png"))!
            precondition(source.size == NSSize(width: 64, height: 64))
            let hasUpdate = name.contains("update")
            let mask = MenuBarIcon.image(resource: name, source: source, hasUpdate: hasUpdate)
            precondition(mask.isTemplate && mask.size == MenuBarIcon.size)
            let bitmap = NSBitmapImageRep(cgImage: mask.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            var greenPixels = 0, visiblePixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0 else { continue }
                    visiblePixels += 1
                    if color.greenComponent > color.redComponent * 1.2 && color.greenComponent > color.blueComponent * 1.2 { greenPixels += 1 }
                }
            }
            precondition(visiblePixels > 50 && greenPixels == 0, "The native tint mask must not include the colored badge")
            if hasUpdate {
                let image = NSBitmapImageRep(cgImage: source.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
                var greenFound = false
                for y in 0..<image.pixelsHigh {
                    for x in 0..<image.pixelsWide {
                        let c = image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                        if c.alphaComponent > 0.9 && c.greenComponent > c.redComponent * 1.2 && c.greenComponent > c.blueComponent * 1.2 { greenFound = true }
                    }
                }
                precondition(greenFound, "The exported update artwork must retain its green dot")
            }
        }
        print("PASS: four Sketch icon assets, native tint masks and separate colored update badge")
    }
}
