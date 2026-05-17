//
//  DaisyMark.swift
//  Daisy
//
//  Static (non-animated) daisy logomark. Two flavours:
//    • `DaisyMark` — SwiftUI View, used inside the app (settings, etc.)
//    • `DaisyMark.menuBarImage` — pre-rendered template NSImage suitable
//      for `MenuBarExtra(label:)`. Bypasses SwiftUI's templating because
//      arbitrary Shape-based views in MenuBarExtra labels don't reliably
//      get tinted by AppKit; an NSImage with `isTemplate = true` always
//      gets the correct light/dark menu-bar treatment.
//

import SwiftUI
import AppKit

struct DaisyMark: View {
    var size: CGFloat = 18
    var tint: Color = .primary

    private let petalCount = 8

    var body: some View {
        let centerR = size * 0.13
        let petalGap = size * 0.01
        let petalWidth = size * 0.18
        let petalLength = size * 0.38

        ZStack {
            ForEach(0..<petalCount, id: \.self) { i in
                let angle = Double(i) * 360.0 / Double(petalCount)
                let offsetY = -(centerR + petalGap + petalLength / 2)
                TeardropShape()
                    .fill(tint)
                    .frame(width: petalWidth, height: petalLength)
                    .offset(y: offsetY)
                    .rotationEffect(.degrees(angle))
            }
            Circle()
                .fill(tint)
                .frame(width: centerR * 2, height: centerR * 2)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - NSImage for the menu bar

@MainActor
extension DaisyMark {
    /// Cached template NSImage rendered once at first access. Pixel size
    /// = 18 × 2 = 36 px (Retina). `isTemplate = true` tells AppKit to
    /// tint it black on a light menu bar and white on a dark one.
    static let menuBarImage: NSImage = {
        // Render the shape solid black on a transparent background;
        // template tinting only uses the alpha channel anyway.
        let view = DaisyMark(size: 18, tint: .black)
            .frame(width: 18, height: 18)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        if let img = renderer.nsImage {
            img.isTemplate = true
            // Point size matters for menu bar layout — pin to 18×18 pt.
            img.size = NSSize(width: 18, height: 18)
            return img
        }
        return NSImage()
    }()
}

#Preview {
    HStack(spacing: 20) {
        DaisyMark(size: 18)
        DaisyMark(size: 36)
        DaisyMark(size: 72, tint: .black)
        DaisyMark(size: 72, tint: .white).background(.black)
    }
    .padding()
}
