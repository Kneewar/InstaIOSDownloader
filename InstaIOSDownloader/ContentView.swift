import SwiftUI
import Photos
import UIKit

struct ContentView: View {
    @State private var link: String = ""
    @State private var status: String = "Paste a direct media URL (.jpg/.png/.mp4) or use the Test buttons."
    @State private var progress: Double = 0
    @State private var isDownloading = false

    var body: some View {
        VStack(spacing: 16) {
            Text("InstaIOSDownloader (Copy Link MVP)")
                .font(.headline)

            TextField("Paste link…", text: $link)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Import from Clipboard") {
                    if let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !s.isEmpty {
                        link = s
                        status = "Imported link from clipboard."
                    } else {
                        status = "No text found on clipboard."
                    }
                }

                Button("Fetch & Save") {
                    Task { await fetchAndSave() }
                }
                .disabled(isDownloading)
            }

            Divider().padding(.vertical, 8)

            // Quick verification buttons
            HStack(spacing: 12) {
                Button("Test Image") {
                    link = "https://upload.wikimedia.org/wikipedia/commons/6/6e/Golde33443.jpg"
                    Task { await fetchAndSave() }
                }
                Button("Test Video") {
                    link = "https://samplelib.com/lib/preview/mp4/sample-5s.mp4"
                    Task { await fetchAndSave() }
                }
            }

            if isDownloading {
                VStack {
                    ProgressView(value: progress)
                        .padding(.horizontal)
                    Text(String(format: "Downloading… %.0f%%", progress * 100))
                        .font(.caption)
                }
            }

            Text(status)
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            Spacer()
        }
        .padding(.top, 20)
        .onAppear { requestPhotoAddPermission() }
    }

    private func fetchAndSave() async {
        guard let url = URL(string: link),
              URLValidator.isProbablyDirectMedia(url: url) else {
            status = "Invalid or non-media URL. Use a direct .jpg/.png/.mp4 or the Test buttons."
            return
        }

        isDownloading = true
        progress = 0
        status = "Starting…"

        do {
            try await Downloader.shared.downloadAndSave(
                from: url,
                onProgress: { prog in
                    DispatchQueue.main.async { self.progress = prog }
                }
            )
            status = "Saved to Photos ✅"
        } catch {
            status = "Download/Save failed: \(error.localizedDescription)"
        }

        isDownloading = false
    }

    private func requestPhotoAddPermission() {
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        } else {
            PHPhotoLibrary.requestAuthorization { _ in }
        }
    }
}

enum URLValidator {
    static func isProbablyDirectMedia(url: URL) -> Bool {
        // simple check: file extension + https scheme
        let okScheme = (url.scheme?.lowercased() == "https")
        let path = url.path.lowercased()
        let isImage = path.hasSuffix(".jpg") || path.hasSuffix(".jpeg") || path.hasSuffix(".png") || path.hasSuffix(".heic")
        let isVideo = path.hasSuffix(".mp4") || path.hasSuffix(".mov") || path.hasSuffix(".m4v")
        return okScheme && (isImage || isVideo)
    }
}
