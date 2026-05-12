import Foundation

enum DebugLog {
    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("macEvnia", isDirectory: true)
            .appendingPathComponent("app.log")
    }()

    private static let queue = DispatchQueue(label: "macEvnia.debugLog")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func write(_ message: String) {
        NSLog("macEvnia: \(message)")
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            do {
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = Data(line.utf8)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: fileURL, options: .atomic)
                }
            } catch {
                NSLog("macEvnia log write failed: \(error.localizedDescription)")
            }
        }
    }
}
