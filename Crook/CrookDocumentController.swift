import AppKit

/// The document controller, with one question answered differently.
///
/// NSDocumentController deduplicates by URL: openDocument(withContentsOf:) asks
/// document(for:) whether that URL is already open, and hands the existing
/// document back if so. That is correct on one machine and wrong across two.
/// /Users/max/.claude/CLAUDE.md on the laptop and /Users/max/.claude/CLAUDE.md
/// on the mini are different files with the same name, and a remote document
/// registered for the second must never be returned for an open of the first —
/// or the mini's text appears under the laptop's file, and ⌘S goes to the
/// wrong machine.
///
/// So a URL only matches a document that belongs to the machine this window
/// is looking at. The first instance created becomes NSDocumentController.shared,
/// which is why main.swift creates this before anything else can.
final class CrookDocumentController: NSDocumentController {

    override func document(for url: URL) -> NSDocument? {
        let want = url.standardizedFileURL.path
        let machine: String? = Providers.current.isLocal ? nil : Providers.current.id
        return documents.first { d in
            guard let c = d as? CrookDocument, let u = c.fileURL else { return false }
            return u.standardizedFileURL.path == want && c.remoteProviderID == machine
        }
    }
}
