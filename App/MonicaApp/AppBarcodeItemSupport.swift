import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import MonicaStorage
import SwiftUI
import UIKit

// 条码条目专用 UI：码图渲染、编辑字段、列表卡片与详情预览。
// 全部使用系统 Core Image；EAN-13 由 MonicaStorage 的纯 Swift 编码器绘制，不引入第三方依赖。

enum BarcodeImageRenderingError: LocalizedError, Equatable {
    case invalidPayload(String)
    case rendererUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload(let message):
            return message
        case .rendererUnavailable(let symbology):
            return String(localized: "当前设备无法生成 \(symbology) 码图。")
        }
    }
}

enum BarcodeImageRenderer {
    private static let quietZone: CGFloat = 12

    /// 校验内容与码制是否匹配，再生成可显示的码图；失败时抛出可读错误，绝不崩溃。
    static func image(payload: String, symbology: BarcodeSymbology) throws -> UIImage {
        let normalized: String
        do {
            normalized = try BarcodePayloadValidator.normalizedPayload(payload, symbology: symbology)
        } catch let error as BarcodePayloadValidationError {
            throw BarcodeImageRenderingError.invalidPayload(error.localizedDescription)
        }

        let cgImage: CGImage
        switch symbology {
        case .qr:
            guard CIFilter(name: "CIQRCodeGenerator") != nil else {
                throw BarcodeImageRenderingError.rendererUnavailable(symbology.displayName)
            }
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(normalized.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage else {
                throw BarcodeImageRenderingError.rendererUnavailable(symbology.displayName)
            }
            cgImage = try rasterize(output, scale: 8)
        case .code128:
            guard CIFilter(name: "CICode128BarcodeGenerator") != nil else {
                throw BarcodeImageRenderingError.rendererUnavailable(symbology.displayName)
            }
            let filter = CIFilter.code128BarcodeGenerator()
            filter.message = Data(normalized.utf8)
            filter.quietSpace = 10
            guard let output = filter.outputImage else {
                throw BarcodeImageRenderingError.rendererUnavailable(symbology.displayName)
            }
            cgImage = try rasterize(output, scale: 3)
        case .pdf417:
            guard CIFilter(name: "CIPDF417BarcodeGenerator") != nil else {
                throw BarcodeImageRenderingError.rendererUnavailable(symbology.displayName)
            }
            let filter = CIFilter.pdf417BarcodeGenerator()
            filter.message = Data(normalized.utf8)
            filter.preferredAspectRatio = 4
            guard let output = filter.outputImage else {
                throw BarcodeImageRenderingError.rendererUnavailable(symbology.displayName)
            }
            cgImage = try rasterize(output, scale: 2)
        case .aztec:
            guard CIFilter(name: "CIAztecCodeGenerator") != nil else {
                throw BarcodeImageRenderingError.rendererUnavailable(symbology.displayName)
            }
            let filter = CIFilter.aztecCodeGenerator()
            filter.message = Data(normalized.utf8)
            filter.correctionLevel = 33
            guard let output = filter.outputImage else {
                throw BarcodeImageRenderingError.rendererUnavailable(symbology.displayName)
            }
            cgImage = try rasterize(output, scale: 8)
        case .ean13:
            cgImage = try ean13Image(normalizedDigits: normalized)
        }

        return UIImage(cgImage: cgImage)
    }

    private static func rasterize(_ image: CIImage, scale: CGFloat) throws -> CGImage {
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = scaled.extent.integral
        guard extent.width > 0, extent.height > 0,
              let cgImage = CIContext(options: nil).createCGImage(scaled, from: extent) else {
            throw BarcodeImageRenderingError.rendererUnavailable("条码")
        }
        return try composeOnWhite(cgImage, padding: quietZone)
    }

    private static func ean13Image(normalizedDigits: String) throws -> CGImage {
        let modules: [Bool]
        do {
            modules = try EAN13Code.modules(for: normalizedDigits)
        } catch let error as BarcodePayloadValidationError {
            throw BarcodeImageRenderingError.invalidPayload(error.localizedDescription)
        }
        guard !modules.isEmpty else {
            throw BarcodeImageRenderingError.rendererUnavailable(BarcodeSymbology.ean13.displayName)
        }

        let moduleWidth = 3
        let quietModules = 9
        let barHeight = 120
        let captionHeight = 22
        let width = (modules.count + quietModules * 2) * moduleWidth
        let height = barHeight + captionHeight + 16
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BarcodeImageRenderingError.rendererUnavailable(BarcodeSymbology.ean13.displayName)
        }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(UIColor.black.cgColor)
        for (index, isBar) in modules.enumerated() where isBar {
            let x = (quietModules + index) * moduleWidth
            context.fill(CGRect(x: x, y: captionHeight + 8, width: moduleWidth, height: barHeight))
        }

        guard let image = context.makeImage() else {
            throw BarcodeImageRenderingError.rendererUnavailable(BarcodeSymbology.ean13.displayName)
        }
        return image
    }

    private static func composeOnWhite(_ image: CGImage, padding: CGFloat) throws -> CGImage {
        let width = image.width + Int(padding * 2)
        let height = image.height + Int(padding * 2)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BarcodeImageRenderingError.rendererUnavailable("条码")
        }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: padding, y: padding, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let composed = context.makeImage() else {
            throw BarcodeImageRenderingError.rendererUnavailable("条码")
        }
        return composed
    }
}

/// 只读码图：内容/码制变化时重新渲染；失败时展示可读错误而不是空白或崩溃。
struct BarcodeCodePreview: View {
    let payload: String
    let symbology: BarcodeSymbology
    var maxHeight: CGFloat = 180

    @State private var image: UIImage?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(maxHeight: maxHeight)
                    .accessibilityLabel(String(localized: "\(symbology.displayName) 码图"))
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .task(id: "\(symbology.rawValue)|\(payload)") {
            render()
        }
    }

    private func render() {
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            image = nil
            errorMessage = nil
            return
        }
        do {
            image = try BarcodeImageRenderer.image(payload: payload, symbology: symbology)
            errorMessage = nil
        } catch {
            image = nil
            errorMessage = error.localizedDescription
        }
    }
}

struct BarcodeEditorFields: View {
    @Binding var title: String
    @Binding var symbology: BarcodeSymbology
    @Binding var payload: String
    @Binding var label: String
    @Binding var notes: String
    var onScan: (() -> Void)?

    private var validationMessage: String? {
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try BarcodePayloadValidator.normalizedPayload(payload, symbology: symbology)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(String(localized: "标题"), text: $title)
                .textFieldStyle(AndroidParityTextFieldStyle())

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "制式"))
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                Picker(String(localized: "制式"), selection: $symbology) {
                    ForEach(BarcodeSymbology.allCases) { symbology in
                        Text(symbology.displayName).tag(symbology)
                    }
                }
                .pickerStyle(.menu)
                .tint(AndroidParityPalette.primary)
                if let onScan {
                    Button(action: onScan) {
                        Label(String(localized: "扫描现有条码"), systemImage: "barcode.viewfinder")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField(String(localized: "原始内容（必填）"), text: $payload, axis: .vertical)
                    .textFieldStyle(AndroidParityTextFieldStyle())
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if symbology == .ean13 {
                    Text(String(localized: "EAN-13 支持 12 位数字（自动补校验位）或 13 位带校验位数字。"))
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }

            TextField(String(localized: "显示标签（可选）"), text: $label)
                .textFieldStyle(AndroidParityTextFieldStyle())

            TextField(String(localized: "备注"), text: $notes, axis: .vertical)
                .textFieldStyle(AndroidParityTextFieldStyle())
                .lineLimit(1...3)

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "码图预览"))
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                BarcodeCodePreview(payload: payload, symbology: symbology)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Text(String(localized: "这里保存并显示条码的原始内容，不会解析或重建登机牌等票据的航空数据。"))
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }
}

struct AndroidBarcodeListCard: View {
    let entry: LocalBarcodeEntry

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.78), cornerRadius: 22) {
            HStack(alignment: .top, spacing: 18) {
                AndroidParityIconTile(systemImage: "barcode.viewfinder", fill: AndroidParityPalette.primaryContainer)
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.title.isEmpty ? String(localized: "未命名") : entry.title)
                        .font(.subheadline.weight(.semibold))
                    Text(entry.payload.isEmpty ? String(localized: "未填写内容") : entry.payload)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .lineLimit(1)
                        .privacySensitive()
                    Text(entry.displaySubtitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary.opacity(0.78))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: entry.favorite ? "heart.fill" : "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(entry.favorite ? AndroidParityPalette.primary : AndroidParityPalette.textSecondary)
            }
        }
    }
}

/// 详情页码图：未显式显示敏感字段时不渲染条码，避免内容直接暴露。
struct BarcodeDetailCodeCard: View {
    let payload: String
    let symbology: BarcodeSymbology
    let isRevealed: Bool

    var body: some View {
        AndroidParityCard {
            if isRevealed {
                BarcodeCodePreview(payload: payload, symbology: symbology, maxHeight: 220)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if !payload.isEmpty {
                    ShareLink(item: payload) {
                        Label(String(localized: "分享条码内容"), systemImage: "square.and.arrow.up")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }
            } else {
                Label(String(localized: "显示敏感字段后可查看并扫描条码"), systemImage: "eye.slash")
                    .font(.subheadline)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 96)
            }
        }
    }
}

/// 扫描现有条码：仅请求本 App 支持的码制；权限被拒、无摄像头或格式不支持时
/// 回退到手动输入，不崩溃。
struct BarcodeScannerSheet: View {
    let onCode: (String, BarcodeSymbology) -> Void
    let onCancel: () -> Void

    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BarcodeScannerView(
                    onCode: { value, symbology in
                        onCode(value, symbology)
                        return true
                    },
                    onUnavailable: { message in
                        statusMessage = message
                    }
                )
                .ignoresSafeArea(edges: .bottom)

                if let statusMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill")
                            .font(.largeTitle)
                        Text(statusMessage)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(24)
                } else {
                    VStack {
                        Spacer()
                        Text(String(localized: "将条码放入取景框内"))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.bottom, 28)
                    }
                }
            }
            .navigationTitle(String(localized: "扫描条码"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消"), action: onCancel)
                }
            }
        }
    }
}

private struct BarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String, BarcodeSymbology) -> Bool
    let onUnavailable: (String) -> Void

    func makeUIViewController(context: Context) -> BarcodeScannerViewController {
        let controller = BarcodeScannerViewController()
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_ uiViewController: BarcodeScannerViewController, context: Context) {
        uiViewController.onCode = onCode
        uiViewController.onUnavailable = onUnavailable
    }
}

private final class BarcodeScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String, BarcodeSymbology) -> Bool)?
    var onUnavailable: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScanCode = false

    private static let supportedTypes: [(AVMetadataObject.ObjectType, BarcodeSymbology)] = [
        (.qr, .qr),
        (.code128, .code128),
        (.ean13, .ean13),
        (.pdf417, .pdf417),
        (.aztec, .aztec)
    ]

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
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureSession()
                    } else {
                        self.reportUnavailable(String(localized: "相机权限未开启，请在「设置 › Monica」中允许相机访问后再扫描。"))
                    }
                }
            }
        case .denied, .restricted:
            reportUnavailable(String(localized: "相机权限未开启，请在「设置 › Monica」中允许相机访问后再扫描。"))
        @unknown default:
            reportUnavailable(String(localized: "相机权限未开启，请在「设置 › Monica」中允许相机访问后再扫描。"))
        }
    }

    private func configureSession() {
        guard previewLayer == nil else { return }
        guard let device = AVCaptureDevice.default(for: .video) else {
            reportUnavailable(String(localized: "此设备没有可用的摄像头，请手动输入条码内容。"))
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            reportUnavailable(String(localized: "无法启动相机，请手动输入条码内容。"))
            return
        }
        captureSession.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            reportUnavailable(String(localized: "无法启动相机，请手动输入条码内容。"))
            return
        }
        captureSession.addOutput(output)
        let requested = Self.supportedTypes.map(\.0)
        let available = Set(output.availableMetadataObjectTypes)
        let usable = requested.filter { available.contains($0) }
        guard !usable.isEmpty else {
            reportUnavailable(String(localized: "当前设备不支持扫描这些条码格式，请手动输入内容。"))
            return
        }
        output.metadataObjectTypes = usable
        output.setMetadataObjectsDelegate(self, queue: .main)

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        startSession()
    }

    private func reportUnavailable(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onUnavailable?(message)
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didScanCode,
              let object = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let value = object.stringValue,
              let symbology = Self.supportedTypes.first(where: { $0.0 == object.type })?.1
        else {
            return
        }
        didScanCode = true
        captureSession.stopRunning()
        if onCode?(value, symbology) != true {
            didScanCode = false
            startSession()
        }
    }

    private func startSession() {
        guard !captureSession.isRunning else { return }
        captureSession.startRunning()
    }
}
