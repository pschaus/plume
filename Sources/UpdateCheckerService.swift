import AppKit
import Foundation
import SwiftUI

struct AppUpdateInfo: Identifiable, Equatable {
    var id: String { version }
    let version: String
    let title: String
    let changelog: String
    let releaseURL: URL
    let dmgDownloadURL: URL
}

@MainActor
final class UpdateCheckerService: ObservableObject {
    static let shared = UpdateCheckerService()

    @Published var availableUpdate: AppUpdateInfo? = nil
    @Published var isCheckingForUpdates: Bool = false
    @Published var lastCheckUpToDateMessage: String? = nil
    @Published var dismissedVersion: String? = nil

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    var shouldShowBanner: Bool {
        guard let update = availableUpdate else { return false }
        return dismissedVersion != update.version
    }

    private init() {}

    func checkForUpdates(manual: Bool = false) async {
        isCheckingForUpdates = true
        lastCheckUpToDateMessage = nil
        defer { isCheckingForUpdates = false }

        // 1. Try GitHub Releases API (/repos/pschaus/plume/releases/latest)
        if let info = await fetchFromGitHubReleases() {
            handleRemoteRelease(info, manual: manual)
            return
        }

        // 2. Fallback to GitHub Pages version.json
        if let info = await fetchFromVersionJSON() {
            handleRemoteRelease(info, manual: manual)
            return
        }

        if manual {
            let isFr = SettingsManager.shared.appLanguage == .french
            lastCheckUpToDateMessage = isFr
                ? "Vous utilisez la dernière version disponible (v\(currentVersion))."
                : "You are running the latest version (v\(currentVersion))."
        }
    }

    private func handleRemoteRelease(_ info: AppUpdateInfo, manual: Bool) {
        if Self.isVersion(info.version, newerThan: currentVersion) {
            self.availableUpdate = info
            if manual {
                self.dismissedVersion = nil
            }
        } else {
            self.availableUpdate = nil
            if manual {
                let isFr = SettingsManager.shared.appLanguage == .french
                self.lastCheckUpToDateMessage = isFr
                    ? "Plume est à jour (v\(currentVersion))."
                    : "Plume is up to date (v\(currentVersion))."
            }
        }
    }

    private func fetchFromGitHubReleases() async -> AppUpdateInfo? {
        guard let url = URL(string: "https://api.github.com/repos/pschaus/plume/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Plume-macOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                return nil
            }

            let cleanVersion = Self.normalizeVersion(tagName)
            let title = (json["name"] as? String) ?? "Plume v\(cleanVersion)"
            let notes = (json["body"] as? String) ?? ""
            let htmlURLString = (json["html_url"] as? String) ?? "https://github.com/pschaus/plume/releases/latest"
            let releaseURL = URL(string: htmlURLString) ?? URL(string: "https://github.com/pschaus/plume/releases")!

            var dmgURLString = "https://github.com/pschaus/plume/releases/latest/download/Plume-macOS.dmg"
            if let assets = json["assets"] as? [[String: Any]] {
                if let dmgAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                   let downloadURL = dmgAsset["browser_download_url"] as? String {
                    dmgURLString = downloadURL
                }
            }
            let dmgURL = URL(string: dmgURLString) ?? releaseURL

            return AppUpdateInfo(
                version: cleanVersion,
                title: title,
                changelog: notes,
                releaseURL: releaseURL,
                dmgDownloadURL: dmgURL
            )
        } catch {
            return nil
        }
    }

    private func fetchFromVersionJSON() async -> AppUpdateInfo? {
        guard let url = URL(string: "https://pschaus.github.io/plume/version.json") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawVersion = json["version"] as? String else {
                return nil
            }

            let cleanVersion = Self.normalizeVersion(rawVersion)
            let title = (json["title"] as? String) ?? "Plume v\(cleanVersion)"
            let notes = (json["notes"] as? String) ?? ""
            let htmlURLString = (json["html_url"] as? String) ?? "https://github.com/pschaus/plume/releases"
            let releaseURL = URL(string: htmlURLString) ?? URL(string: "https://github.com/pschaus/plume/releases")!

            var dmgURLString = "https://github.com/pschaus/plume/releases/latest/download/Plume-macOS.dmg"
            if let assets = json["assets"] as? [String: Any],
               let macosAsset = assets["macos"] as? String {
                dmgURLString = macosAsset
            }
            let dmgURL = URL(string: dmgURLString) ?? releaseURL

            return AppUpdateInfo(
                version: cleanVersion,
                title: title,
                changelog: notes,
                releaseURL: releaseURL,
                dmgDownloadURL: dmgURL
            )
        } catch {
            return nil
        }
    }

    // MARK: - SemVer Comparison

    static func normalizeVersion(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            trimmed.removeFirst()
        }
        return trimmed
    }

    static func isVersion(_ remote: String, newerThan current: String) -> Bool {
        let rParts = normalizeVersion(remote).split(separator: ".").compactMap { Int($0) }
        let cParts = normalizeVersion(current).split(separator: ".").compactMap { Int($0) }
        let maxCount = max(rParts.count, cParts.count)
        for i in 0..<maxCount {
            let r = i < rParts.count ? rParts[i] : 0
            let c = i < cParts.count ? cParts[i] : 0
            if r != c {
                return r > c
            }
        }
        return false
    }
}

// MARK: - Changelog Modal Sheet

struct UpdateChangelogSheet: View {
    let update: AppUpdateInfo
    let currentVersion: String
    let lang: AppLanguage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PlumeLogoView(size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lang == .french
                         ? "Mise à jour disponible : \(update.title)"
                         : "Update Available: \(update.title)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(lang == .french
                         ? "Version installée : v\(currentVersion) → Nouvelle version : v\(update.version)"
                         : "Installed version: v\(currentVersion) → New version: v\(update.version)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(lang == .french ? "Fermer" : "Close") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            Divider()

            Text(lang == .french ? "Nouveautés & Changelog :" : "Release Notes & Changelog:")
                .font(.system(size: 13, weight: .semibold))

            ScrollView {
                Text(update.changelog.isEmpty
                     ? (lang == .french ? "Consultez la page GitHub pour les détails de cette version." : "See the GitHub release page for details.")
                     : update.changelog)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            )

            HStack {
                Button {
                    NSWorkspace.shared.open(update.releaseURL)
                } label: {
                    Label(lang == .french ? "Voir sur GitHub" : "View on GitHub", systemImage: "safari")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    NSWorkspace.shared.open(update.dmgDownloadURL)
                    dismiss()
                } label: {
                    Label(
                        lang == .french ? "Télécharger Plume v\(update.version) (.dmg)" : "Download Plume v\(update.version) (.dmg)",
                        systemImage: "arrow.down.circle.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.310, green: 0.275, blue: 0.898))
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }
}
