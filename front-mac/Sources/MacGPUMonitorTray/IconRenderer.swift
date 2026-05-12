import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Mirror of the gpu-monitor-tray macOS renderer, adapted for the Apple
// Silicon GPU schema: only one GPU per snapshot, donut shows memory %,
// the label shows temperature (or " -ºC" when the chip — e.g. plain M1/M2 —
// doesn't expose a GPU thermal sensor).
enum IconAppearance: Sendable {
    case dark
    case light
}

enum IconColors {
    static let free   = CGColor(red: 0x66/255.0, green: 0xb3/255.0, blue: 0xff/255.0, alpha: 1.0)
    static let ok     = CGColor(red: 0x33/255.0, green: 0xb0/255.0, blue: 0x33/255.0, alpha: 1.0)
    static let warn1  = CGColor(red: 0xe6/255.0, green: 0xb8/255.0, blue: 0x00/255.0, alpha: 1.0)
    static let warn2  = CGColor(red: 0xff/255.0, green: 0xa0/255.0, blue: 0x40/255.0, alpha: 1.0)
    static let high   = CGColor(red: 0xe0/255.0, green: 0x33/255.0, blue: 0x33/255.0, alpha: 1.0)

    static let dimFree = CGColor(red: 0x80/255.0, green: 0x80/255.0, blue: 0x80/255.0, alpha: 1.0)
    static let dimUsed = CGColor(red: 0x60/255.0, green: 0x60/255.0, blue: 0x60/255.0, alpha: 1.0)

    static func text(_ a: IconAppearance) -> CGColor {
        CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    }
    static func dimText(_ a: IconAppearance) -> CGColor {
        CGColor(red: 0xbb/255.0, green: 0xbb/255.0, blue: 0xbb/255.0, alpha: 1.0)
    }
}

private let donutPadding: CGFloat = 2
private let innerLabelSize: CGFloat = 8

/// Donut "used" color from GPU utilization. Same green/yellow/orange/red
/// thresholds as the Linux GPU tray.
private func usedColor(_ pct: Float) -> CGColor {
    if pct >= 90 { return IconColors.high }
    if pct >= 80 { return IconColors.warn2 }
    if pct >= 70 { return IconColors.warn1 }
    return IconColors.ok
}

private func textSize(forHeight h: CGFloat) -> CGFloat {
    let raw = (h * 0.45).rounded()
    return max(8, min(16, raw))
}

/// Label shown to the left of the donut: GPU temperature. Apple Silicon
/// chips that don't expose a GPU thermal sensor (plain M1 / M2) render
/// " -ºC" instead — the donut still carries memory % so the slot is useful.
private func sideLabel(for gpu: GPU?) -> String {
    guard let g = gpu else { return " -ºC" }
    if let t = g.temperatureC {
        return String(format: "%2dºC", Int(t))
    }
    return " -ºC"
}

struct IconRenderer {
    let height: CGFloat
    let baseIcon: CGImage?

    init(height: CGFloat) {
        self.height = height
        self.baseIcon = Self.loadBaseIcon(targetHeight: height)
    }

    @MainActor
    func renderImage(gpu: GPU?, connected: Bool, appearance: IconAppearance) -> NSImage? {
        guard let result = renderCGImage(gpu: gpu, connected: connected, appearance: appearance) else {
            return nil
        }
        let img = NSImage(cgImage: result.cgImage, size: result.logicalSize)
        img.isTemplate = false
        return img
    }

    /// Runs without AppKit so it is safe from any thread (used by --dump-icon).
    func renderPNG(
        gpu: GPU?,
        connected: Bool,
        to path: String,
        appearance: IconAppearance = .dark
    ) throws {
        guard let result = renderCGImage(gpu: gpu, connected: connected, appearance: appearance) else {
            throw NSError(domain: "IconRenderer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "render failed"])
        }
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw NSError(domain: "IconRenderer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "could not create PNG destination"])
        }
        CGImageDestinationAddImage(dest, result.cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "IconRenderer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
    }

    private struct RenderResult {
        let cgImage: CGImage
        let logicalSize: CGSize
    }

    private func renderCGImage(gpu: GPU?, connected: Bool, appearance: IconAppearance) -> RenderResult? {
        let scale: CGFloat = 2
        let layout = self.layout(gpu: gpu, scale: scale, connected: connected, appearance: appearance)
        let pxW = max(1, Int(layout.totalLogicalWidth * scale))
        let pxH = max(1, Int(height * scale))

        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: scale, y: -scale)

        draw(layout: layout, ctx: ctx, connected: connected)

        guard let cg = ctx.makeImage() else { return nil }
        return RenderResult(
            cgImage: cg,
            logicalSize: CGSize(width: layout.totalLogicalWidth, height: height)
        )
    }

    // MARK: - Layout

    private struct Layout {
        let totalLogicalWidth: CGFloat
        let donutSize: CGFloat
        let iconWidth: CGFloat
        let textWidth: CGFloat
        let textPx: CGFloat
        let gpu: GPU?
        let connected: Bool
        let appearance: IconAppearance
    }

    private func layout(gpu: GPU?, scale: CGFloat, connected: Bool, appearance: IconAppearance) -> Layout {
        let textPx = textSize(forHeight: height)
        // Worst case is 4 mono-digit chars: "00ºC".
        let probeWidth = measureText("00ºC", size: textPx)
        let donutSize = max(8, height - donutPadding * 2)
        let iconW: CGFloat = baseIcon.map { CGFloat($0.width) / scale } ?? 0

        let total: CGFloat
        if gpu == nil {
            let dashW = measureText("-", size: textPx)
            total = iconW + 4 + dashW + 2
        } else {
            total = iconW + 2 + probeWidth + 2 + donutSize
        }
        return Layout(
            totalLogicalWidth: max(height, total),
            donutSize: donutSize,
            iconWidth: iconW,
            textWidth: probeWidth,
            textPx: textPx,
            gpu: gpu,
            connected: connected,
            appearance: appearance
        )
    }

    // MARK: - Drawing

    private func draw(layout: Layout, ctx: CGContext, connected: Bool) {
        guard let gpu = layout.gpu else {
            var x: CGFloat = 0
            if let icon = baseIcon {
                let iconHpt = CGFloat(icon.height) / 2.0
                let iconWpt = CGFloat(icon.width) / 2.0
                let iconY = (height - iconHpt) / 2.0
                ctx.saveGState()
                ctx.interpolationQuality = .high
                ctx.setAlpha(0.4)
                ctx.translateBy(x: x, y: iconY + iconHpt)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(icon, in: CGRect(x: 0, y: 0, width: iconWpt, height: iconHpt))
                ctx.restoreGState()
                x += iconWpt + 4
            }
            drawText(
                "-",
                ctx: ctx,
                x: x,
                size: layout.textPx,
                color: IconColors.dimText(layout.appearance),
                blockHeight: height
            )
            return
        }

        drawGPUBlock(ctx: ctx, originX: 0, gpu: gpu, layout: layout)
    }

    private func drawGPUBlock(ctx: CGContext, originX x: CGFloat, gpu: GPU, layout: Layout) {
        if let icon = baseIcon {
            let iconHpt = CGFloat(icon.height) / 2.0
            let iconWpt = CGFloat(icon.width) / 2.0
            let iconY = (height - iconHpt) / 2.0
            let rect = CGRect(x: x, y: iconY, width: iconWpt, height: iconHpt)
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.translateBy(x: rect.origin.x, y: rect.origin.y + rect.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(icon, in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
        }

        let label = sideLabel(for: gpu)
        let labelColor = layout.connected
            ? IconColors.text(layout.appearance)
            : IconColors.dimText(layout.appearance)
        let textX = x + layout.iconWidth + 2
        drawText(
            label,
            ctx: ctx,
            x: textX,
            size: layout.textPx,
            color: labelColor,
            blockHeight: height
        )

        let donutX = x + layout.iconWidth + 2 + layout.textWidth + 2
        let usedPct = Float(max(0, min(100, gpu.utilization.memoryPercent)))
        drawDonut(
            ctx: ctx,
            x: donutX,
            y: donutPadding,
            size: layout.donutSize,
            usedPercent: usedPct,
            connected: layout.connected
        )

        let pctText = "\(Int(usedPct.rounded()))"
        let pctW = measureText(pctText, size: innerLabelSize)
        let pctX = donutX + layout.donutSize / 2 - pctW / 2
        let pctColor = layout.connected
            ? IconColors.text(layout.appearance)
            : IconColors.dimText(layout.appearance)
        drawText(
            pctText,
            ctx: ctx,
            x: pctX,
            size: innerLabelSize,
            color: pctColor,
            blockHeight: height
        )
    }

    private func drawDonut(
        ctx: CGContext,
        x: CGFloat,
        y: CGFloat,
        size: CGFloat,
        usedPercent: Float,
        connected: Bool
    ) {
        let cx = x + size / 2
        let cy = y + size / 2
        let rOuter = size / 2
        let rInner = rOuter * 0.78

        let freeColor = connected ? IconColors.free : IconColors.dimFree
        ctx.saveGState()
        ctx.setFillColor(freeColor)
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: rOuter, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
        ctx.restoreGState()

        if usedPercent > 0.5 {
            let color = connected ? usedColor(usedPercent) : IconColors.dimUsed
            let sweep = CGFloat(usedPercent) / 100.0 * (.pi * 2)
            let start = -CGFloat.pi / 2
            let end = start + sweep
            ctx.saveGState()
            ctx.setFillColor(color)
            ctx.move(to: CGPoint(x: cx, y: cy))
            ctx.addArc(
                center: CGPoint(x: cx, y: cy),
                radius: rOuter,
                startAngle: start,
                endAngle: end,
                clockwise: false
            )
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: rInner, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: - Text (CoreText, system mono-digit)

    private static func font(size: CGFloat) -> CTFont {
        let nsf = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        return nsf as CTFont
    }

    private func measureText(_ text: String, size: CGFloat) -> CGFloat {
        let line = makeLine(text: text, size: size, color: IconColors.text(.dark))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return CGFloat(width)
    }

    private func makeLine(text: String, size: CGFloat, color: CGColor) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font(size: size),
            .foregroundColor: color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        return CTLineCreateWithAttributedString(attributed)
    }

    private func drawText(
        _ text: String,
        ctx: CGContext,
        x: CGFloat,
        size: CGFloat,
        color: CGColor,
        blockHeight: CGFloat
    ) {
        let line = makeLine(text: text, size: size, color: color)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        let baselineFromTop = ((blockHeight - size) / 2.0).rounded() + ascent

        ctx.saveGState()
        ctx.translateBy(x: x, y: baselineFromTop)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Base icon loading

    private static func loadBaseIcon(targetHeight: CGFloat) -> CGImage? {
        guard let url = Bundle.module.url(forResource: "gpu", withExtension: "png"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }

        let pxH = Int(targetHeight * 2)
        let aspect = CGFloat(cg.width) / CGFloat(cg.height)
        let pxW = max(1, Int((targetHeight * 2 * aspect).rounded()))

        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))
        return ctx.makeImage()
    }
}
