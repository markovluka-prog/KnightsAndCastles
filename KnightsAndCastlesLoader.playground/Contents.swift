import SwiftUI
import WebKit
import PlaygroundSupport

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class RepoLoader: ObservableObject {
    @Published var statusText = "Preparing..."
    @Published var indexURL: URL?

    private let repoURL = "https://github.com/markovluka-prog/KnightsAndCastles" // Put your Git repository URL here.
    private var didStart = false

    private lazy var repoDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("KnightsAndCastlesCache", isDirectory: true)
    }()

    var repositoryRoot: URL { repoDirectory }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true

        Task {
            await load()
        }
    }

    private func load() async {
        statusText = "Checking internet..."
        let online = await hasInternetConnection()

        if online {
            statusText = "Internet is available. Updating from Git..."
            do {
                try syncRepository()
                statusText = "Repository updated."
            } catch {
                statusText = "Git update failed: \(error.localizedDescription). Trying cached version..."
            }
        } else {
            statusText = "Offline mode. Using cached version..."
        }

        let localIndex = repoDirectory.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: localIndex.path) {
            indexURL = localIndex
            statusText = online ? "Running latest local copy." : "Running cached local copy."
        } else {
            statusText = "No cached version found. Connect to internet once to download."
        }
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

    private func syncRepository() throws {
        let fm = FileManager.default

        try fm.createDirectory(
            at: repoDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let gitFolder = repoDirectory.appendingPathComponent(".git")
        if fm.fileExists(atPath: gitFolder.path) {
            _ = try runGit(["-C", repoDirectory.path, "pull", "--ff-only"])
            return
        }

        if fm.fileExists(atPath: repoDirectory.path) {
            try fm.removeItem(at: repoDirectory)
        }

        _ = try runGit([
            "clone",
            "--depth",
            "1",
            repoURL,
            repoDirectory.path
        ])
    }

    private func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        let combined = [out, err]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus != 0 {
            throw NSError(
                domain: "GitSync",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: combined.isEmpty ? "Unknown git error." : combined]
            )
        }

        return combined
    }
}

#if os(macOS)
struct WebContainer: NSViewRepresentable {
    let indexURL: URL
    let rootURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.loadFileURL(indexURL, allowingReadAccessTo: rootURL)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != indexURL {
            nsView.loadFileURL(indexURL, allowingReadAccessTo: rootURL)
        }
    }
}
#else
struct WebContainer: UIViewRepresentable {
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
#endif

struct ContentView: View {
    @StateObject private var loader = RepoLoader()

    var body: some View {
        VStack(spacing: 12) {
            Text(loader.statusText)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            if let indexURL = loader.indexURL {
                WebContainer(indexURL: indexURL, rootURL: loader.repositoryRoot)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                Spacer()
                Text("No local version available yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .onAppear {
            loader.startIfNeeded()
        }
    }
}

let rootView = ContentView()

#if os(macOS)
PlaygroundPage.current.liveView = NSHostingController(rootView: rootView)
#else
PlaygroundPage.current.setLiveView(UIHostingController(rootView: rootView))
#endif

PlaygroundPage.current.needsIndefiniteExecution = true
