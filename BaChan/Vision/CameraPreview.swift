import SwiftUI
import AVFoundation

/// A small live preview of the active camera, backed by
/// `AVCaptureVideoPreviewLayer`. Used as a thumbnail so the user can see what
/// Ba-Chan is looking at. Shows nothing on the Simulator (no camera). The public
/// `CameraPreview(session:)` API is identical on both platforms; only the
/// representable bridge differs (UIKit on iOS, AppKit on macOS).

#if os(iOS)
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

#elseif os(macOS)
import AppKit

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}

    // NSView has no overridable `layerClass`; instead it's made layer-hosting by
    // returning our preview layer from `makeBackingLayer()` and setting `wantsLayer`.
    final class PreviewView: NSView {
        let videoPreviewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = videoPreviewLayer
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func makeBackingLayer() -> CALayer { videoPreviewLayer }
    }
}
#endif
