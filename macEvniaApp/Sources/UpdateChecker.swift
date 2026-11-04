import Foundation

struct ReleaseVersion: Comparable, CustomStringConvertible {
    private let components: [Int]

    init?(_ value: String) {
        var version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct GitHubRelease: Codable, Equatable {
    let tagName: String
    let pageURL: URL
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case pageURL = "html_url"
        case draft, prerelease
    }
}

struct AvailableUpdate: Equatable {
    let version: ReleaseVersion
    let pageURL: URL

    static func newerRelease(_ release: GitHubRelease, than installedVersion: String) throws -> AvailableUpdate? {
        guard !release.draft, !release.prerelease else { return nil }
        guard let installed = ReleaseVersion(installedVersion), let latest = ReleaseVersion(release.tagName) else {
            throw UpdateCheckError.invalidVersion
        }
        let url = URLComponents(url: release.pageURL, resolvingAgainstBaseURL: false)
        guard url?.scheme == "https", url?.host?.lowercased() == "github.com",
              url?.user == nil, url?.password == nil, url?.port == nil, url?.query == nil, url?.fragment == nil,
              let path = url?.path, path.lowercased().hasPrefix("/funk4d/macevnia/releases/tag/"),
              path.count > "/funk4d/macEvnia/releases/tag/".count else {
            throw UpdateCheckError.invalidReleaseURL
        }
        return latest > installed ? AvailableUpdate(version: latest, pageURL: release.pageURL) : nil
    }
}

enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case http(Int)
    case invalidVersion
    case invalidReleaseURL

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub returned an invalid response."
        case .http(let code): return "GitHub returned HTTP \(code). Try again later."
        case .invalidVersion: return "The release version could not be read."
        case .invalidReleaseURL: return "The release does not link to the macEvnia GitHub repository."
        }
    }
}

final class UpdateChecker {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/funk4d/macEvnia/releases/latest")!
    static let checkInterval: TimeInterval = 6 * 60 * 60
    private static let cachedReleaseKey = "macevnia.updates.cachedRelease"
    private static let skippedVersionKey = "macevnia.updates.skippedVersion"

    private let installedVersion: String
    private let session: URLSession
    private let defaults: UserDefaults?
    private var skippedVersion: String?
    private var lastAttempt: Date?
    private var lastCheckSucceeded = false
    private var timer: Timer?
    private var task: URLSessionDataTask?
    private var completions: [(Result<AvailableUpdate?, Error>) -> Void] = []

    private(set) var latestUpdate: AvailableUpdate?
    private(set) var isChecking = false
    var onChange: (() -> Void)?

    var availableUpdate: AvailableUpdate? {
        guard let latestUpdate, latestUpdate.version.description != skippedVersion else { return nil }
        return latestUpdate
    }

    init(installedVersion: String, session: URLSession? = nil, defaults: UserDefaults? = .standard,
         previewRelease: GitHubRelease? = nil) {
        self.installedVersion = installedVersion
        self.defaults = defaults
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: configuration)
        }
        skippedVersion = defaults?.string(forKey: Self.skippedVersionKey)
        let cached = defaults?.data(forKey: Self.cachedReleaseKey)
            .flatMap { try? JSONDecoder().decode(GitHubRelease.self, from: $0) }
        if let release = previewRelease ?? cached {
            latestUpdate = try? AvailableUpdate.newerRelease(release, than: installedVersion)
        }
    }

    func start() {
        guard timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
        timer?.tolerance = 5 * 60
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
    }

    func check(force: Bool = false, completion: ((Result<AvailableUpdate?, Error>) -> Void)? = nil) {
        if isChecking {
            if let completion { completions.append(completion) }
            return
        }
        let interval = lastCheckSucceeded ? Self.checkInterval : 60 * 60
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < interval {
            completion?(.success(latestUpdate))
            return
        }
        if let completion { completions.append(completion) }
        lastAttempt = Date()
        isChecking = true
        onChange?()

        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("macEvnia/\(installedVersion)", forHTTPHeaderField: "User-Agent")
        DebugLog.write("Checking GitHub releases (installed=\(installedVersion))")
        task = session.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<GitHubRelease, Error> = Result {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse, let data else { throw UpdateCheckError.invalidResponse }
                guard response.statusCode == 200 else { throw UpdateCheckError.http(response.statusCode) }
                return try JSONDecoder().decode(GitHubRelease.self, from: data)
            }
            DispatchQueue.main.async { [weak self] in
                self?.finish(result)
            }
        }
        task?.resume()
    }

    func skipAvailableUpdate() {
        guard let update = availableUpdate else { return }
        skippedVersion = update.version.description
        defaults?.set(skippedVersion, forKey: Self.skippedVersionKey)
        DebugLog.write("Skipped update \(update.version)")
        onChange?()
    }

    private func finish(_ result: Result<GitHubRelease, Error>) {
        task = nil
        isChecking = false
        let outcome = result.flatMap { release -> Result<AvailableUpdate?, Error> in
            Result {
                let update = try AvailableUpdate.newerRelease(release, than: installedVersion)
                latestUpdate = update
                if let data = try? JSONEncoder().encode(release) {
                    defaults?.set(data, forKey: Self.cachedReleaseKey)
                }
                return update
            }
        }
        switch outcome {
        case .success(let update):
            lastCheckSucceeded = true
            DebugLog.write(update.map { "Update available: \($0.version)" } ?? "macEvnia is up to date")
        case .failure(let error):
            lastCheckSucceeded = false
            DebugLog.write("Update check failed: \(error.localizedDescription)")
        }
        let callbacks = completions
        completions.removeAll()
        onChange?()
        callbacks.forEach { $0(outcome) }
    }

    deinit { stop() }
}
