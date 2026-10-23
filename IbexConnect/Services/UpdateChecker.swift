import Foundation

/// A newer release on GitHub than the running build.
nonisolated struct AvailableUpdate: Sendable, Equatable {
    let version: String
    /// The zip when the release has one, else the release page.
    let downloadURL: URL
}

/// Asks GitHub for the latest release and compares it with the running
/// version. The app can't install anything itself (it's distributed as a
/// zip), so the result is only ever shown with a link.
nonisolated enum UpdateChecker {
    static let repository = "SattamAltwaim/IbexConnect"
    static let assetName = "IbexConnect.zip"

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let assets: [Asset]
    }

    /// The running version, from the tag the release workflow stamped in.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// nil when up to date, offline, rate-limited, or on a dev build whose
    /// version doesn't look like a release.
    static func check() async -> AvailableUpdate? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("IbexConnect/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data)
        else { return nil }

        let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard isNewer(latest, than: currentVersion) else { return nil }
        let asset = release.assets.first { $0.name == assetName }
        return AvailableUpdate(version: latest, downloadURL: asset?.browser_download_url ?? release.html_url)
    }

    /// Dotted numeric comparison: 1.0.10 > 1.0.9, and 1.1 == 1.1.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
