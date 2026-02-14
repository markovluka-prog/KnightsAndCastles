import SwiftUI
import WebKit

private struct GitTreeResponse: Decodable {
    let tree: [GitTreeEntry]
}

private struct GitTreeEntry: Decodable {
    let path: String
    let type: String
    let sha: String
}

@MainActor
final class GameWebLoader: ObservableObject {
    @Published var statusText = "Preparing web app..."
    @Published var indexURL: URL?

    private let repoOwner = "markovluka-prog"
    private let repoName = "KnightsAndCastles"
    private let branch = "main"
    private var didStart = false

    private lazy var appSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("KnightsAndCastlesLoader", isDirectory: true)
    }()

    private lazy var localWebDirectory: URL = {
        appSupportDirectory.appendingPathComponent("Web", isDirectory: true)
    }()

    private lazy var signatureFileURL: URL = {
        appSupportDirectory.appendingPathComponent("web_signature.txt")
    }()

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true

        Task {
            await load()
        }
    }

    private func load() async {
        do {
            try ensureLocalWebExists()
            indexURL = localIndexURLIfAvailable()
        } catch {
            statusText = "Failed to prepare local files: \(error.localizedDescription)"
        }

        statusText = "Checking internet..."
        let online = await hasInternetConnection()

        if online {
            statusText = "Internet is available. Updating from GitHub..."
            do {
                let didUpdate = try await updateWebFilesFromGitHub()
                statusText = didUpdate ? "Updated to latest web version." : "Already up to date."
            } catch {
                statusText = "Update failed. Using local version. Error: \(error.localizedDescription)"
            }
        } else {
            statusText = "Offline mode. Using local web version."
        }

        if let localIndex = localIndexURLIfAvailable() {
            indexURL = localIndex
            if !online {
                statusText = "Offline mode. Running cached version."
            }
        } else {
            statusText = "No local version found."
        }
    }

    private func ensureLocalWebExists() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)

        if fm.fileExists(atPath: localWebDirectory.path),
           fm.fileExists(atPath: localWebDirectory.appendingPathComponent("index.html").path) {
            return
        }

        guard let bundledWebURL = Bundle.module.resourceURL?.appendingPathComponent("Web", isDirectory: true),
              fm.fileExists(atPath: bundledWebURL.path) else {
            throw NSError(
                domain: "WebLoader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Bundled Web resources were not found."]
            )
        }

        if fm.fileExists(atPath: localWebDirectory.path) {
            try fm.removeItem(at: localWebDirectory)
        }

        try fm.copyItem(at: bundledWebURL, to: localWebDirectory)
    }

    private func localIndexURLIfAvailable() -> URL? {
        let index = localWebDirectory.appendingPathComponent("index.html")
        return FileManager.default.fileExists(atPath: index.path) ? index : nil
    }

    private func hasInternetConnection() async -> Bool {
        guard let url = URL(string: "https://github.com") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...499).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func updateWebFilesFromGitHub() async throws -> Bool {
        let tree = try await fetchRemoteTree()
        let webFiles = tree
            .filter { $0.type == "blob" && isWebFile(path: $0.path) }
            .sorted { $0.path < $1.path }

        if webFiles.isEmpty {
            throw NSError(
                domain: "WebLoader",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No web files were found in the repository."]
            )
        }

        let remoteSignature = webFiles.map { "\($0.path):\($0.sha)" }.joined(separator: "\n")
        let localSignature = try? String(contentsOf: signatureFileURL, encoding: .utf8)

        if localSignature == remoteSignature {
            return false
        }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("KnightsAndCastlesLoader-\(UUID().uuidString)", isDirectory: true)

        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        do {
            for (index, file) in webFiles.enumerated() {
                if index % 25 == 0 {
                    statusText = "Downloading files \(index + 1)/\(webFiles.count)..."
                }

                let data = try await downloadRawFile(path: file.path)
                let destination = tempRoot.appendingPathComponent(file.path)
                let parent = destination.deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            }

            try replaceLocalWeb(with: tempRoot)
            try remoteSignature.write(to: signatureFileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            try? fm.removeItem(at: tempRoot)
            throw error
        }
    }

    private func replaceLocalWeb(with stagedDirectory: URL) throws {
        let fm = FileManager.default
        let backupURL = appSupportDirectory.appendingPathComponent("Web_backup", isDirectory: true)

        if fm.fileExists(atPath: backupURL.path) {
            try fm.removeItem(at: backupURL)
        }

        if fm.fileExists(atPath: localWebDirectory.path) {
            try fm.moveItem(at: localWebDirectory, to: backupURL)
        }

        do {
            try fm.moveItem(at: stagedDirectory, to: localWebDirectory)
            if fm.fileExists(atPath: backupURL.path) {
                try fm.removeItem(at: backupURL)
            }
        } catch {
            if fm.fileExists(atPath: localWebDirectory.path) {
                try? fm.removeItem(at: localWebDirectory)
            }
            if fm.fileExists(atPath: backupURL.path) {
                try? fm.moveItem(at: backupURL, to: localWebDirectory)
            }
            throw error
        }
    }

    private func fetchRemoteTree() async throws -> [GitTreeEntry] {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/git/trees/\(branch)?recursive=1") else {
            throw NSError(
                domain: "WebLoader",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid GitHub API URL."]
            )
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KnightsAndCastlesLoader", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "WebLoader",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "GitHub API request failed."]
            )
        }

        let decoded = try JSONDecoder().decode(GitTreeResponse.self, from: data)
        return decoded.tree
    }

    private func downloadRawFile(path: String) async throws -> Data {
        guard var url = URL(string: "https://raw.githubusercontent.com/\(repoOwner)/\(repoName)/\(branch)") else {
            throw NSError(
                domain: "WebLoader",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Invalid raw content base URL."]
            )
        }

        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("KnightsAndCastlesLoader", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "WebLoader",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Failed downloading \(path)."]
            )
        }

        return data
    }

    private func isWebFile(path: String) -> Bool {
        path == "index.html" || path.hasPrefix("assets/") || path.hasPrefix("public/")
    }
}

struct GameWebView: UIViewRepresentable {
    let indexURL: URL
    let rootURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.loadFileURL(indexURL, allowingReadAccessTo: rootURL)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url != indexURL {
            uiView.loadFileURL(indexURL, allowingReadAccessTo: rootURL)
        }
    }
}

struct ContentView: View {
    @StateObject private var loader = GameWebLoader()

    var body: some View {
        VStack(spacing: 10) {
            Text(loader.statusText)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            if let indexURL = loader.indexURL {
                GameWebView(indexURL: indexURL, rootURL: indexURL.deletingLastPathComponent())
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                Spacer()
                Text("No local web content available.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .onAppear {
            loader.startIfNeeded()
        }
    }
}
