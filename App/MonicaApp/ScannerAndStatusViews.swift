import AVFoundation
import MonicaUI
import Observation
import SwiftUI
import UIKit

struct TotpQRCodeScannerSheet: View {
    @Bindable var session: AppSessionModel
    let onCode: (String) -> Bool
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            QRCodeScannerView(onCode: onCode)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("扫描二维码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", action: onCancel)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if case .failed(let message) = session.entryOperationState {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(.red.opacity(0.88))
                    }
                }
        }
    }
}

private struct QRCodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Bool

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let controller = QRCodeScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {
        uiViewController.onCode = onCode
    }
}

private final class QRCodeScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Bool)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScanCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureWhenAuthorized()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    private func configureWhenAuthorized() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else {
                    return
                }
                DispatchQueue.main.async {
                    self?.configureSession()
                }
            }
        case .denied, .restricted:
            return
        @unknown default:
            return
        }
    }

    private func configureSession() {
        guard previewLayer == nil,
              let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input)
        else {
            return
        }

        captureSession.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            return
        }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        captureSession.startRunning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didScanCode,
              let object = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              object.type == .qr,
              let value = object.stringValue
        else {
            return
        }

        didScanCode = true
        captureSession.stopRunning()
        if onCode?(value) != true {
            didScanCode = false
            captureSession.startRunning()
        }
    }
}

struct AutoFillStatusView: View {
    let appGroupIdentifier: String

    var body: some View {
        AndroidParityScreen {
            AndroidParitySection(title: "自动填充") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    AndroidParityInfoRow(title: "索引", value: "已加密")
                    AndroidParityInfoRow(title: "App Group", value: appGroupIdentifier)
                }
            }
        }
        .navigationTitle("自动填充")
        .navigationBarTitleDisplayMode(.inline)
    }
}
