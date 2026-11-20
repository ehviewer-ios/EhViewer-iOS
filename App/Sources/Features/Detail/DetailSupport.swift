import SwiftUI
import UIKit
import NukeUI
import Nuke
import EhCore

// MARK: - 流式布局（tag 换行排列）

struct DetailFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = size(of: v, maxWidth: maxWidth)
            if x > 0, x + s.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += s.width
            widest = max(widest, x)
            x += spacing
            lineHeight = max(lineHeight, s.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for v in subviews {
            let s = size(of: v, maxWidth: maxWidth)
            if x > 0, x + s.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }

    private func size(of v: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = v.sizeThatFits(.unspecified)
        if ideal.width <= maxWidth { return ideal }
        return v.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}

// MARK: - 站内链接路由（对应 UrlOpener.openUrl(context, url, true)）

@MainActor
enum DetailLinkRouter {
    /// 站内链接转为 Route 并回调 push；外部链接交给系统
    static func handle(_ url: URL, app: AppModel, push: @escaping (Route) -> Void) -> OpenURLAction.Result {
        guard let route = EhUrlRoute.parseEhUrl(url.absoluteString) else { return .systemAction }
        switch route {
        case let .galleryList(builder):
            push(.list(builder, title: nil))
        case let .galleryDetail(gid, token):
            push(.galleryToken(gid: gid, token: token))
        case let .galleryPage(gid, pToken, page):
            Task {
                do {
                    let token = try await app.api.getGalleryToken(gid: gid, gtoken: pToken, page: page)
                    push(.galleryToken(gid: gid, token: token))
                } catch {
                    app.toast.error(error)
                }
            }
        case .external:
            return .systemAction
        }
        return .handled
    }
}

// MARK: - 封面大图

/// 封面查看器：UIScrollView 缩放（捏合、拖动、双击），未放大时下滑关闭
struct DetailCoverViewer: View {
    let url: String?
    let referer: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    @State private var dismissProgress: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - dismissProgress * 0.7)
                .ignoresSafeArea()
            if let image {
                DetailZoomableImage(image: image, onDismiss: { dismiss() }, onDragProgress: { dismissProgress = $0 })
                    .ignoresSafeArea()
                    .accessibilityLabel("封面")
                    .accessibilityAddTraits(.isImage)
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("封面加载失败")
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.25))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .padding()
            .opacity(1 - dismissProgress)
            .accessibilityLabel("关闭")
        }
        .statusBarHidden()
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { dismiss() }
        .task {
            guard let request = ImageRequest.eh(url, referer: referer) else {
                failed = true
                return
            }
            do {
                image = try await ImagePipeline.shared.image(for: request)
            } catch {
                failed = true
            }
        }
    }
}

/// 可缩放图片（UIScrollView）。双击放大到点击处 / 还原；未放大时向下拖动关闭
struct DetailZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onDismiss: () -> Void
    let onDragProgress: (CGFloat) -> Void

    func makeUIView(context: Context) -> DetailZoomScrollView {
        let v = DetailZoomScrollView()
        v.setImage(image)
        return v
    }

    func updateUIView(_ view: DetailZoomScrollView, context: Context) {
        view.onDismiss = onDismiss
        view.onDragProgress = onDragProgress
        if view.image !== image { view.setImage(image) }
    }
}

final class DetailZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private let dismissPan = UIPanGestureRecognizer()
    private var lastBounds: CGSize = .zero
    var onDismiss: (() -> Void)?
    var onDragProgress: ((CGFloat) -> Void)?

    var image: UIImage? { imageView.image }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        imageView.contentMode = .scaleToFill
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        dismissPan.addTarget(self, action: #selector(handleDismissPan(_:)))
        addGestureRecognizer(dismissPan)
        // 未放大时优先识别下滑关闭；放大时 dismissPan 立即失败，不影响拖动
        panGestureRecognizer.require(toFail: dismissPan)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: UIImage) {
        imageView.image = image
        lastBounds = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastBounds, let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        lastBounds = bounds.size
        minimumZoomScale = 1
        maximumZoomScale = 1
        zoomScale = 1
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        imageView.frame = CGRect(x: 0, y: 0, width: size.width * fit, height: size.height * fit)
        contentSize = imageView.frame.size
        minimumZoomScale = 1
        maximumZoomScale = max(4, 1 / fit)
        centerImage()
    }

    private func centerImage() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let p = g.location(in: imageView)
        let target = min(maximumZoomScale, 2.5)
        let w = bounds.width / target, h = bounds.height / target
        zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
    }

    // MARK: 下滑关闭

    /// UIView 对挂在自身上的所有手势调用此方法
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === dismissPan else { return super.gestureRecognizerShouldBegin(g) }
        let v = dismissPan.velocity(in: self)
        return zoomScale <= minimumZoomScale * 1.01 && v.y > 0 && v.y > abs(v.x) * 1.5
    }

    @objc private func handleDismissPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        let progress = min(max(t.y / max(bounds.height * 0.5, 1), 0), 1)
        switch g.state {
        case .changed:
            let scale = 1 - 0.2 * progress
            imageView.transform = CGAffineTransform(translationX: t.x * 0.5, y: max(t.y, 0)).scaledBy(x: scale, y: scale)
            onDragProgress?(progress)
        case .ended, .cancelled, .failed:
            let v = g.velocity(in: self).y
            if g.state == .ended, t.y > 120 || (t.y > 40 && v > 900) {
                onDismiss?()
                return
            }
            let reset = {
                self.imageView.transform = .identity
            }
            onDragProgress?(0)
            if UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.2, animations: reset)
            } else {
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                               options: [.allowUserInteraction], animations: reset)
            }
        default:
            break
        }
    }
}

// MARK: - 区块标题

struct DetailSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            trailing()
        }
    }
}

extension DetailSectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.title = title
        self.trailing = { EmptyView() }
    }
}

// MARK: - 评论 HTML 渲染（对应 Html.fromHtml + TextUrl.handleTextUrl）

/// 轻量 HTML → AttributedString：支持 br/p/div、a、b/strong、i/em、u、s/del、带样式的 span、img（显示为链接），
/// 普通文本中的网址自动识别为链接。站点评论只用这些标签，无需 WebKit 的完整 HTML 导入
@MainActor
enum CommentHTMLRenderer {
    private static var cache: [String: AttributedString] = [:]

    private struct Frame {
        var tag: String
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var link: URL?
    }

    private static let tagRegex = try! NSRegularExpression(pattern: "<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>", options: [])
    private static let attrRegex = try! NSRegularExpression(
        pattern: "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: [])
    private static let entityRegex = try! NSRegularExpression(pattern: "&(#[xX]?[0-9a-fA-F]+|[a-zA-Z]+);", options: [])
    private static let whitespaceRegex = try! NSRegularExpression(pattern: "\\s+", options: [])
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func render(_ html: String) -> AttributedString {
        if let hit = cache[html] { return hit }
        let result = build(html)
        if cache.count > 500 { cache.removeAll() }
        cache[html] = result
        return result
    }

    /// 纯文本（复制评论用）
    static func plainText(_ html: String) -> String {
        String(render(html).characters)
    }

    private static func build(_ html: String) -> AttributedString {
        var out = AttributedString()
        var stack: [Frame] = []
        let ns = html as NSString
        var cursor = 0

        func endsWithNewline() -> Bool {
            guard let last = out.characters.last else { return true }
            return last == "\n"
        }

        func container() -> AttributeContainer {
            var c = AttributeContainer()
            var intent: InlinePresentationIntent = []
            var underline = false
            var link: URL?
            for f in stack {
                if f.bold { intent.insert(.stronglyEmphasized) }
                if f.italic { intent.insert(.emphasized) }
                if f.strike { intent.insert(.strikethrough) }
                if f.underline { underline = true }
                if let l = f.link { link = l }
            }
            if !intent.isEmpty { c.inlinePresentationIntent = intent }
            if underline { c[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single }
            if let link { c.link = link }
            return c
        }

        func appendText(_ raw: String) {
            var text = whitespaceRegex.stringByReplacingMatches(
                in: raw, range: NSRange(location: 0, length: (raw as NSString).length), withTemplate: " ")
            text = decodeEntities(text)
            if endsWithNewline() {
                text = String(text.drop(while: { $0 == " " }))
            }
            guard !text.isEmpty else { return }
            let attrs = container()
            if attrs.link == nil, let detector = linkDetector {
                let tns = text as NSString
                var pos = 0
                for m in detector.matches(in: text, range: NSRange(location: 0, length: tns.length)) {
                    guard let url = m.url, url.scheme?.hasPrefix("http") == true else { continue }
                    if m.range.location > pos {
                        out.append(AttributedString(tns.substring(with: NSRange(location: pos, length: m.range.location - pos)), attributes: attrs))
                    }
                    var linkAttrs = attrs
                    linkAttrs.link = url
                    out.append(AttributedString(tns.substring(with: m.range), attributes: linkAttrs))
                    pos = m.range.location + m.range.length
                }
                if pos < tns.length {
                    out.append(AttributedString(tns.substring(from: pos), attributes: attrs))
                }
            } else {
                out.append(AttributedString(text, attributes: attrs))
            }
        }

        func newline(force: Bool) {
            if force || !endsWithNewline() { out.append(AttributedString("\n")) }
        }

        for m in tagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                appendText(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            }
            cursor = m.range.location + m.range.length
            let closing = ns.substring(with: m.range(at: 1)) == "/"
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            let attrText = ns.substring(with: m.range(at: 3))

            if closing {
                switch name {
                case "p", "div": newline(force: false)
                default: break
                }
                if let i = stack.lastIndex(where: { $0.tag == name }) { stack.remove(at: i) }
                continue
            }

            let attrs = parseAttributes(attrText)
            switch name {
            case "br":
                newline(force: true)
            case "p", "div":
                if !out.characters.isEmpty { newline(force: false) }
                stack.append(Frame(tag: name))
            case "a":
                var f = Frame(tag: name)
                if let href = attrs["href"].map(decodeEntities), let url = URL(string: href.trimmingCharacters(in: .whitespaces)) {
                    f.link = url
                }
                stack.append(f)
            case "b", "strong":
                stack.append(Frame(tag: name, bold: true))
            case "i", "em":
                stack.append(Frame(tag: name, italic: true))
            case "u", "ins":
                stack.append(Frame(tag: name, underline: true))
            case "s", "strike", "del":
                stack.append(Frame(tag: name, strike: true))
            case "span", "font":
                let style = (attrs["style"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")
                stack.append(Frame(
                    tag: name,
                    bold: style.contains("font-weight:bold"),
                    italic: style.contains("font-style:italic"),
                    underline: style.contains("underline"),
                    strike: style.contains("line-through")
                ))
            case "img":
                var c = container()
                if c.link == nil, let src = attrs["src"].map(decodeEntities), let url = URL(string: src) {
                    c.link = url
                }
                out.append(AttributedString("[图片]", attributes: c))
            default:
                break
            }
            // 自闭合标签不入栈（br/img 已处理）
            if attrText.hasSuffix("/"), let last = stack.last, last.tag == name { stack.removeLast() }
        }
        if cursor < ns.length {
            appendText(ns.substring(from: cursor))
        }
        while let last = out.characters.last, last.isWhitespace {
            out.characters.removeLast()
        }
        return out
    }

    private static func parseAttributes(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        let ns = s as NSString
        for m in attrRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            for i in 2...4 where m.range(at: i).location != NSNotFound {
                result[key] = ns.substring(with: m.range(at: i))
                break
            }
        }
        return result
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var out = ""
        var pos = 0
        for m in entityRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            let body = ns.substring(with: m.range(at: 1))
            if let rep = entity(body) {
                out += rep
            } else {
                out += ns.substring(with: m.range)
            }
            pos = m.range.location + m.range.length
        }
        out += ns.substring(from: pos)
        return out
    }

    private static func entity(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        switch body {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "hellip": return "…"
        case "mdash": return "—"
        case "ndash": return "–"
        case "copy": return "©"
        default: return nil
        }
    }
}
