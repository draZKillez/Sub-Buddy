import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// A direct UIKit document picker is used instead of SwiftUI's `fileImporter`.
/// LiveContainer hosts guest apps inside another process, and the SwiftUI wrapper
/// can fail to deliver custom-UTI selections in that environment. Opening in
/// place is essential here: copying a multi-gigabyte MKV into the app sandbox
/// would be both slow and wasteful.
struct SystemFilePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Accept any file at the picker boundary. Some file providers classify
        // MKV as public.data instead of the imported Matroska UTI. The app checks
        // the filename extension immediately after selection.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item],
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private var parent: SystemFilePicker
        private var deliveredResult = false

        init(parent: SystemFilePicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !deliveredResult else { return }
            deliveredResult = true
            parent.isPresented = false
            guard let url = urls.first else {
                parent.onCancel()
                return
            }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !deliveredResult else { return }
            deliveredResult = true
            parent.isPresented = false
            parent.onCancel()
        }
    }
}
