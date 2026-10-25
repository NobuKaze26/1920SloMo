import SwiftUI
import OSLog
import UIKit

/// Space the interactive overlay should leave clear of the device fold.
/// Always `.zero` on devices without a division region, so conventional iPhones are unaffected.
struct HingeInsets: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0
    /// Minimum vertical gap between the top and bottom overlay groups (tabletop-style folds).
    var gap: CGFloat = 0
    /// True on a foldable: it reports a fold region now or did before, or has a large uneven side safe area.
    var isFoldable = false
    /// Foldables only: right safe-area inset minus left, used to re-center content.
    var safeAreaImbalance: CGFloat = 0
    /// Foldables only: actual left/right safe-area insets, for full-bleed overlays that must stay clear of them.
    var safeLeft: CGFloat = 0
    var safeRight: CGFloat = 0
    var viewWidth: CGFloat = 0

    static let zero = HingeInsets()
}

/// Non-interactive, full-bleed probe that reads the system's division regions (the fold)
/// and reports how far interactive controls need to stay away from it.
struct HingeProbe: UIViewRepresentable {
    @Binding var insets: HingeInsets

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.onChange = { newInsets in
            if insets != newInsets { insets = newInsets }
        }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onChange = { newInsets in
            if insets != newInsets { insets = newInsets }
        }
    }

    final class ProbeView: UIView {
        var onChange: ((HingeInsets) -> Void)?
        private var lastReported = HingeInsets.zero

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        private func report() {
            let insets = currentInsets()
            guard insets != lastReported else { return }
            lastReported = insets
            // Defer so SwiftUI state isn't mutated during a layout pass.
            Task { @MainActor [weak self] in
                self?.onChange?(insets)
            }
        }

        private func currentInsets() -> HingeInsets {
            // Reserved regions are new in 27.1; earlier releases never have a fold.
            guard #available(iOS 27.1, *), let window, bounds.width > 0, bounds.height > 0 else {
                return .zero
            }
            var result = HingeInsets.zero
            let left = window.safeAreaInsets.left
            let right = window.safeAreaInsets.right
            // A foldable reports a division region even while inactive, but the closed (outer)
            // display reports none. So also accept a fold seen before, or a side system bar
            // (large uneven side inset) that conventional iPhones never have.
            let seenKey = "hasSeenFoldRegion"
            if !reservedRegions(kind: .division, options: [.includeInactive]).isEmpty {
                UserDefaults.standard.set(true, forKey: seenKey)
            }
            result.isFoldable = UserDefaults.standard.bool(forKey: seenKey) || abs(right - left) >= 40
            guard result.isFoldable else { return .zero }
            // Uneven safe areas push content off-center on foldables, in any orientation.
            // Zero when the insets are symmetric.
            result.safeAreaImbalance = right - left
            result.safeLeft = left
            result.safeRight = right
            result.viewWidth = bounds.width
            for region in reservedRegions(kind: .division) where region.isActive {
                let frame = region.frame.intersection(bounds)
                guard !frame.isNull, !frame.isEmpty else { continue }
                if frame.height >= bounds.height * 0.8 {
                    // Vertical crease: keep controls on the wider side (physical left/right).
                    let leadingSpace = frame.minX
                    let trailingSpace = bounds.width - frame.maxX
                    if leadingSpace >= trailingSpace {
                        result.right = max(result.right, bounds.width - frame.minX)
                    } else {
                        result.left = max(result.left, frame.maxX)
                    }
                } else if frame.width >= bounds.width * 0.8 {
                    // Horizontal crease: separate the top and bottom control groups.
                    result.gap = max(result.gap, frame.height)
                }
            }
            return result
        }
    }
}
