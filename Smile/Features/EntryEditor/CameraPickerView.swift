import SwiftUI
import UIKit

// MARK: - UIImagePickerController wrapper for camera

struct CameraPickerView: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerView
        init(_ parent: CameraPickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let img = info[.originalImage] as? UIImage else { parent.onCancel(); return }
            parent.onCapture(img)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

// MARK: - CameraFlow: camera → crop → callback

struct CameraFlow: View {
    var onFinish: (UIImage) -> Void
    var onCancel: () -> Void

    @State private var capturedImage: UIImage? = nil

    var body: some View {
        if let img = capturedImage {
            PhotoCropView(image: img) { cropped in
                onFinish(cropped)
            } onCancel: {
                capturedImage = nil
                onCancel()
            }
        } else {
            CameraPickerView { img in
                capturedImage = img
            } onCancel: {
                onCancel()
            }
        }
    }
}
