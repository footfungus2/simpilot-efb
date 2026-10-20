import PencilKit
import SwiftUI
import UIKit

/// Pinch-zoomable chart page with the ownship drawn on georeferenced pages.
struct ZoomableChartView: UIViewRepresentable {
    let image: UIImage
    let night: Bool
    let page: ChartPage
    let ownship: Ownship?
    /// Changes when another chart/page is shown, which resets the zoom.
    let resetKey: String
    /// Keep the aircraft centred (zoomed in), like Navigraph's follow mode. Panning by hand turns it off.
    var follow = false
    var onUserPan: () -> Void = {}
    /// Annotate mode: fingers draw too and the tool picker shows. The Apple Pencil always draws on charts.
    var annotating = false
    /// Bumped by the toolbar's "clear" to wipe this page's annotations.
    var clearToken = 0

    func makeUIView(context: Context) -> ChartScrollView {
        ChartScrollView()
    }

    func updateUIView(_ view: ChartScrollView, context: Context) {
        view.show(image: image, night: night, key: resetKey)
        view.follow = follow
        view.onUserPan = onUserPan
        view.setAnnotations(key: resetKey, chartSize: CGSize(width: page.width, height: page.height))
        view.setAnnotating(annotating)
        view.clearAnnotations(token: clearToken)
        view.updateOwnship(page: page, ownship: ownship)
    }
}

final class ChartScrollView: UIScrollView, UIScrollViewDelegate, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    private let imageView = UIImageView()
    // Annotations: a transparent PencilKit canvas on the chart, zooming with it.
    private let canvas = PKCanvasView()
    private let toolPicker = PKToolPicker()
    private var annotationKey: String?
    private var chartSize: CGSize = .zero
    private var canvasWidth: CGFloat = 0
    private var annotating = false
    private var clearToken = 0
    private var saveWork: DispatchWorkItem?
    private var loading = false
    private var inkTool: PKTool = PKInkingTool(.pen, color: UIColor(hex: 0xE5302A), width: 3)
    private var previousTool: PKTool = PKInkingTool(.marker, color: UIColor(hex: 0xF5C518).withAlphaComponent(0.6), width: 12)
    private let ownshipLayer = CAShapeLayer()
    private let haloLayer = CAShapeLayer()
    private var shownKey: String?
    private var shownNight: Bool?
    private var sourceImage: UIImage?
    var follow = false
    var onUserPan: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        haloLayer.fillColor = UIColor(hex: 0x3D8BFF, alpha: 0.3).cgColor
        ownshipLayer.fillColor = UIColor(hex: 0x3D8BFF).cgColor
        ownshipLayer.strokeColor = UIColor.white.cgColor
        ownshipLayer.lineWidth = 1
        imageView.isUserInteractionEnabled = true
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .pencilOnly // the Pencil always draws; fingers pan and zoom the chart
        canvas.tool = inkTool
        canvas.delegate = self
        imageView.addSubview(canvas)
        // Keep the ownship above the ink.
        imageView.layer.addSublayer(haloLayer)
        imageView.layer.addSublayer(ownshipLayer)
        toolPicker.addObserver(canvas)

        // Apple Pencil double-tap: follows the user's system setting (eraser / previous tool / palette).
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(image: UIImage, night: Bool, key: String) {
        if key != shownKey || image !== sourceImage {
            shownKey = key
            sourceImage = image
            shownNight = nil
            zoomScale = 1
        }
        if shownNight != night {
            shownNight = night
            imageView.image = night ? NightChart.render(image) : image
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, zoomScale == 1 else { return }
        // Fit the page into the view at zoom 1.
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centerContent()
        layoutCanvas()
    }

    // MARK: Annotations

    /// The canvas covers the page at its zoom-1 size; ink is rescaled if that size changes (e.g. rotation).
    private func layoutCanvas() {
        let w = imageView.bounds.width
        guard w > 0 else { return }
        if canvasWidth > 0, abs(canvasWidth - w) > 0.5, !canvas.drawing.strokes.isEmpty {
            loading = true
            canvas.drawing = canvas.drawing.transformed(using: CGAffineTransform(scaleX: w / canvasWidth, y: w / canvasWidth))
            loading = false
        }
        canvas.frame = imageView.bounds
        if canvasWidth == 0 || abs(canvasWidth - w) > 0.5 {
            canvasWidth = w
            loadDrawingIfNeeded()
        }
    }

    func setAnnotations(key: String, chartSize: CGSize) {
        guard key != annotationKey else { return }
        saveNow()
        annotationKey = key
        self.chartSize = chartSize
        canvasWidth = 0
        loading = true
        canvas.drawing = PKDrawing()
        loading = false
        setNeedsLayout()
    }

    private func loadDrawingIfNeeded() {
        guard let key = annotationKey, chartSize.width > 0, canvasWidth > 0 else { return }
        loading = true
        let stored = AnnotationStore.load(key) ?? PKDrawing()
        let k = canvasWidth / chartSize.width // chart units → view points
        canvas.drawing = stored.transformed(using: CGAffineTransform(scaleX: k, y: k))
        loading = false
    }

    func setAnnotating(_ on: Bool) {
        guard on != annotating else { return }
        annotating = on
        canvas.drawingPolicy = on ? .anyInput : .pencilOnly
        // While annotating one finger draws, so panning the chart takes two.
        panGestureRecognizer.minimumNumberOfTouches = on ? 2 : 1
        toolPicker.setVisible(on, forFirstResponder: canvas)
        if on { canvas.becomeFirstResponder() } else { canvas.resignFirstResponder() }
    }

    func clearAnnotations(token: Int) {
        guard token != clearToken else { return }
        clearToken = token
        canvas.undoManager?.registerUndo(withTarget: canvas) { [drawing = canvas.drawing] c in c.drawing = drawing }
        canvas.drawing = PKDrawing()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !loading else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func saveNow() {
        saveWork?.cancel()
        guard let key = annotationKey, chartSize.width > 0, canvasWidth > 0 else { return }
        let k = chartSize.width / canvasWidth // view points → chart units
        AnnotationStore.save(canvas.drawing.transformed(using: CGAffineTransform(scaleX: k, y: k)), key: key)
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        // With the tool picker on screen, PencilKit handles double-tap itself.
        guard !toolPicker.isVisible else { return }
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser:
            if canvas.tool is PKEraserTool {
                canvas.tool = inkTool
            } else {
                inkTool = canvas.tool
                canvas.tool = PKEraserTool(.vector)
            }
        case .switchPrevious:
            let current = canvas.tool
            canvas.tool = previousTool
            previousTool = current
        case .showColorPalette:
            toolPicker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        default:
            break
        }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        // Re-render ink at the new zoom so it stays sharp.
        canvas.contentScaleFactor = UIScreen.main.scale * scale
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { onUserPan() }

    private func centerContent() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let p = g.location(in: imageView)
            zoom(to: CGRect(x: p.x - 100, y: p.y - 100, width: 200, height: 200), animated: true)
        }
    }

    /// Positions the ownship symbol in the image view's (unzoomed) coordinate space.
    func updateOwnship(page: ChartPage, ownship: Ownship?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let o = ownship, page.width > 0, let pos = page.position(lat: o.lat, lon: o.lon) else {
            ownshipLayer.isHidden = true
            haloLayer.isHidden = true
            return
        }
        // The image view's bounds stay at the zoom-1 size; zooming applies a transform on top.
        let sx = imageView.bounds.width / page.width
        let sy = imageView.bounds.height / page.height
        let p = CGPoint(x: pos.x * sx, y: pos.y * sy)
        let s: CGFloat = 1 / max(zoomScale, 1) // keep the symbol a constant on-screen size

        haloLayer.isHidden = false
        ownshipLayer.isHidden = false
        haloLayer.path = UIBezierPath(arcCenter: .zero, radius: 22, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
        let plane = UIBezierPath()
        plane.move(to: CGPoint(x: 0, y: -12))
        plane.addLine(to: CGPoint(x: 9, y: 10))
        plane.addLine(to: CGPoint(x: 0, y: 5))
        plane.addLine(to: CGPoint(x: -9, y: 10))
        plane.close()
        ownshipLayer.path = plane.cgPath
        let t = CATransform3DScale(CATransform3DMakeRotation(CGFloat(o.trkDeg * .pi / 180), 0, 0, 1), s, s, 1)
        ownshipLayer.position = p
        ownshipLayer.transform = t
        haloLayer.position = p
        haloLayer.transform = CATransform3DMakeScale(s, s, 1)

        if follow && !isDragging && !isZooming {
            if zoomScale < 2 { setZoomScale(2.5, animated: false) }
            let target = CGPoint(x: p.x * zoomScale - bounds.width / 2, y: p.y * zoomScale - bounds.height / 2)
            let maxX = max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)
            let maxY = max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom)
            setContentOffset(CGPoint(x: min(max(target.x, -contentInset.left), maxX),
                                     y: min(max(target.y, -contentInset.top), maxY)), animated: false)
        }
    }
}
