import AppKit
import ContainerDeskCore
import UniformTypeIdentifiers

@MainActor
enum ImageArchivePanels {
    static func load() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Load Image Archive"
        panel.prompt = "Load"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.archive, .data]

        return await withCheckedContinuation { continuation in
            let complete: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }

            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window, completionHandler: complete)
            } else {
                panel.begin(completionHandler: complete)
            }
        }
    }

    static func save(image: ResourceSummary) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Image Archive"
        panel.prompt = "Save"
        let reference = image.details.imageReference ?? image.id
        let platform = image.details.platform.map { " (\($0))" } ?? ""
        panel.message = "Save an archive of \(reference)\(platform)."
        panel.nameFieldStringValue = "\(safeFilename(from: reference)).tar"
        panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .archive]
        panel.canCreateDirectories = true

        return await withCheckedContinuation { continuation in
            let complete: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }

            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window, completionHandler: complete)
            } else {
                panel.begin(completionHandler: complete)
            }
        }
    }

    private static func safeFilename(from title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let sanitized = title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let filename = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        return filename.isEmpty ? "image" : filename
    }
}
