//
//  WifiQRCodeRenderer.swift
//  Monica
//
//  Wi-Fi 二维码渲染（CoreImage 生成分享图）。
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum WifiQRCodeRenderer {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func image(for payload: String, size: CGFloat = 192) -> UIImage? {
        guard !payload.isEmpty,
              let data = payload.data(using: .utf8)
        else {
            return nil
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let extent = outputImage.extent.integral
        let scale = max(1, floor(size / max(extent.width, extent.height)))
        let transformed = outputImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let renderedSize = CGSize(width: extent.width * scale, height: extent.height * scale)

        guard let cgImage = context.createCGImage(transformed, from: CGRect(origin: .zero, size: renderedSize)) else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { rendererContext in
            UIColor.white.setFill()
            rendererContext.fill(CGRect(x: 0, y: 0, width: size, height: size))
            rendererContext.cgContext.interpolationQuality = .none
            let origin = CGPoint(
                x: floor((size - renderedSize.width) / 2),
                y: floor((size - renderedSize.height) / 2)
            )
            UIImage(cgImage: cgImage, scale: 1, orientation: .up)
                .draw(in: CGRect(origin: origin, size: renderedSize))
        }
    }
}
