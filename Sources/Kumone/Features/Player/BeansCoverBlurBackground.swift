// Sources/Kumone/Features/Player/BeansCoverBlurBackground.swift
//
// Beans blurred-cover background (ported from Beans-Music
// `CoverBlurBackground.swift`): the current cover, pre-blurred once per
// track on a background queue and shown as a static layer, with a
// gradient washed from the cover's own top/bottom average colours, a
// slow breathing scale and a swaying gradient.
//
// Why a UIKit layer, not SwiftUI `.blur()`: the blur is computed once
// per track change (not a live full-screen effect, which is the
// battery/heat cost Beans measured), and the view holds a fixed
// full-screen frame, so a cover finishing loading never triggers a
// SwiftUI layout pass — the "cover loads, layout jumps" class of bug
// cannot happen here.
//
// Adaptation for Golia: Beans loads the cover from a URL itself; Golia's
// player page already loads the artwork (`NowPlayingView.artworkImage`),
// so this view takes the loaded image + a cache key instead of a URL —
// no second download, no second decode. Track changes cross-dissolve;
// the gradient falls back to the passed artwork palette colours.

#if os(iOS)

import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Full-screen blurred-cover background for the player page.
struct BeansCoverBlurBackground: UIViewRepresentable {
    /// The already-loaded cover image (nil while loading / no artwork).
    let image: PlatformImage?
    /// Cache identity for the image (artwork URL string or track id).
    let cacheKey: String
    /// Fallback gradient colours (the artwork palette pair).
    let primary: Color
    let secondary: Color
    let scheme: ColorScheme
    /// Static mode / Reduce Motion: no breathing or gradient sway.
    let isStatic: Bool

    func makeUIView(context: Context) -> BeansCoverBlurView {
        let view = BeansCoverBlurView()
        view.updateScheme(scheme)
        view.updateStatic(isStatic)
        view.load(image: image, cacheKey: cacheKey, primary: primary, secondary: secondary)
        return view
    }

    func updateUIView(_ uiView: BeansCoverBlurView, context: Context) {
        uiView.updateScheme(scheme)
        uiView.updateStatic(isStatic)
        uiView.load(image: image, cacheKey: cacheKey, primary: primary, secondary: secondary)
    }
}

final class BeansCoverBlurView: UIView {
    private let imageView = UIImageView()
    private let gradientLayer = CAGradientLayer()
    private let gradientHost = UIView()
    private let tintView = UIView()
    private var currentCacheKey: String?
    private var currentIsStatic = false
    private static let imageCache = NSCache<NSString, UIImage>()
    private static let blurQueue = DispatchQueue(label: "golia.beansCoverBlur", qos: .utility)
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = false
        tintView.isUserInteractionEnabled = false
        gradientHost.isUserInteractionEnabled = false

        gradientLayer.colors = [UIColor.systemGray.cgColor, UIColor.systemGray2.cgColor]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        // Transparent until a blurred cover arrives: the wash must not
        // dull the artwork gradient underneath while there is no cover.
        gradientLayer.opacity = 0
        gradientHost.layer.addSublayer(gradientLayer)

        addSubview(imageView)
        addSubview(gradientHost)
        addSubview(tintView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientHost.frame = bounds
        gradientLayer.frame = bounds
        imageView.frame = bounds
        tintView.frame = bounds
    }

    /// Background motion: the blurred cover slowly breathes (scale) and
    /// the gradient endpoints sway. Long-period, low-frequency, GPU
    /// composited — no SwiftUI layout, almost no battery cost.
    private func startBackgroundAnimations() {
        imageView.layer.removeAnimation(forKey: "beansBgBreathe")
        gradientLayer.removeAnimation(forKey: "beansGradStart")
        gradientLayer.removeAnimation(forKey: "beansGradEnd")
        imageView.transform = .identity
        guard !currentIsStatic else { return }

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.10
        scale.duration = 14
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageView.layer.add(scale, forKey: "beansBgBreathe")

        let start = CABasicAnimation(keyPath: "startPoint")
        start.fromValue = NSValue(cgPoint: CGPoint(x: 0.5, y: 0))
        start.toValue = NSValue(cgPoint: CGPoint(x: 0.68, y: 0))
        start.duration = 12
        start.autoreverses = true
        start.repeatCount = .infinity
        start.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradientLayer.add(start, forKey: "beansGradStart")

        let end = CABasicAnimation(keyPath: "endPoint")
        end.fromValue = NSValue(cgPoint: CGPoint(x: 0.5, y: 1))
        end.toValue = NSValue(cgPoint: CGPoint(x: 0.32, y: 1))
        end.duration = 12
        end.autoreverses = true
        end.repeatCount = .infinity
        end.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradientLayer.add(end, forKey: "beansGradEnd")
    }

    func updateScheme(_ scheme: ColorScheme) {
        // Light/dark scrim: keeps foreground text and controls readable.
        tintView.backgroundColor = scheme == .dark
            ? UIColor.black.withAlphaComponent(0.30)
            : UIColor.white.withAlphaComponent(0.10)
    }

    func updateStatic(_ isStatic: Bool) {
        guard isStatic != currentIsStatic else { return }
        currentIsStatic = isStatic
        startBackgroundAnimations()
    }

    func load(image: PlatformImage?, cacheKey: String, primary: Color, secondary: Color) {
        guard let image else {
            // Already empty: never re-apply the fallback wash on every
            // SwiftUI re-evaluation.
            guard currentCacheKey != nil || imageView.image != nil else { return }
            currentCacheKey = nil
            imageView.image = nil
            gradientLayer.opacity = 0
            return
        }
        // Same artwork: never reload or re-set, however often SwiftUI
        // re-evaluates the parent view.
        if currentCacheKey == cacheKey { return }
        currentCacheKey = cacheKey

        if let cached = Self.imageCache.object(forKey: cacheKey as NSString) {
            setImage(cached, animated: false)
            applyGradientIfNeeded(for: cacheKey, fallbackTop: UIColor(primary), fallbackBottom: UIColor(secondary))
            return
        }

        Self.blurQueue.async {
            let blurred = Self.makeBlurredImage(image)
            let colors = Self.extractGradientColors(from: image)
            if let blurred {
                Self.imageCache.setObject(blurred, forKey: cacheKey as NSString)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentCacheKey == cacheKey else { return }
                if let blurred { self.setImage(blurred, animated: true) }
                self.applyGradient(colors)
            }
        }
    }

    /// Cover-tinted gradient, animated over 0.6s.
    private func applyGradient(_ colors: (top: UIColor, bottom: UIColor)) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        gradientLayer.colors = [colors.top.cgColor, colors.bottom.cgColor]
        CATransaction.commit()
    }

    private func applyGradient(top: UIColor, bottom: UIColor) {
        applyGradient((top: top, bottom: bottom))
    }

    private func applyGradientIfNeeded(for cacheKey: String, fallbackTop: UIColor, fallbackBottom: UIColor) {
        if let cached = Self.imageCache.object(forKey: cacheKey as NSString) {
            applyGradient(Self.extractGradientColors(from: cached))
        } else {
            applyGradient(top: fallbackTop, bottom: fallbackBottom)
        }
    }

    /// Gradient from the cover's own colours: the top half's average
    /// lightened, the bottom half's darkened.
    private static func extractGradientColors(from image: UIImage) -> (top: UIColor, bottom: UIColor) {
        let sample = image.preparingThumbnail(of: CGSize(width: 200, height: 200)) ?? image
        // CIImage origin is bottom-left: visual top = y 0.5...1.0,
        // visual bottom = y 0...0.5.
        let top = areaAverage(of: sample, in: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
            ?? UIColor.systemGray
        let bottom = areaAverage(of: sample, in: CGRect(x: 0, y: 0, width: 1, height: 0.5))
            ?? UIColor.systemGray2
        return (top.lightened(0.28), bottom.darkened(0.48))
    }

    private static func areaAverage(of image: UIImage, in normalizedRect: CGRect) -> UIColor? {
        guard let ci = CIImage(image: image) else { return nil }
        let extent = ci.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let region = CGRect(
            x: extent.minX + extent.width * normalizedRect.minX,
            y: extent.minY + extent.height * normalizedRect.minY,
            width: extent.width * normalizedRect.width,
            height: extent.height * normalizedRect.height
        )
        let filter = CIFilter.areaAverage()
        filter.inputImage = ci
        filter.extent = region
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    /// One-shot Gaussian blur: downscale first, then blur, then show
    /// full-screen — a stronger look for less work.
    private static func makeBlurredImage(_ source: UIImage) -> UIImage? {
        let target = source.preparingThumbnail(of: CGSize(width: 480, height: 480)) ?? source
        guard let input = CIImage(image: target) else { return target }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input
        filter.radius = 36
        guard let output = filter.outputImage else { return target }
        let extent = output.extent
        guard extent.width > 0, extent.height > 0,
              let cg = ciContext.createCGImage(output, from: extent) else { return target }
        return UIImage(cgImage: cg)
    }

    private func setImage(_ image: UIImage, animated: Bool) {
        gradientLayer.opacity = 0.62
        guard animated, imageView.image != nil else {
            imageView.image = image
            startBackgroundAnimations()
            return
        }
        UIView.transition(
            with: imageView,
            duration: 0.4,
            options: [.transitionCrossDissolve, .beginFromCurrentState]
        ) {
            self.imageView.image = image
        } completion: { _ in
            // Re-assert the background motion after the cross-dissolve.
            self.startBackgroundAnimations()
        }
    }
}

private extension UIColor {
    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let a = min(max(amount, 0), 1)
        return UIColor(
            red: r1 * (1 - a) + r2 * a,
            green: g1 * (1 - a) + g2 * a,
            blue: b1 * (1 - a) + b2 * a,
            alpha: 1
        )
    }

    func lightened(_ amount: CGFloat) -> UIColor { mixed(with: .white, amount: amount) }
    func darkened(_ amount: CGFloat) -> UIColor { mixed(with: .black, amount: amount) }
}

#endif
