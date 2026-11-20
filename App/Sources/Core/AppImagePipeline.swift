import Foundation
import Nuke
import UIKit
import EhNetwork

/// Nuke 数据加载器：所有缩略图/预览请求走 `EhHTTPClient`，从而支持域前置、自定义 hosts、Cookie 与 Referer。
final class EhDataLoader: DataLoading, @unchecked Sendable {
    private let clientProvider: @Sendable () -> EhHTTPClient?

    init(clientProvider: @escaping @Sendable () -> EhHTTPClient?) {
        self.clientProvider = clientProvider
    }

    private final class TaskBox: Cancellable, @unchecked Sendable {
        var task: Task<Void, Never>?
        func cancel() { task?.cancel() }
    }

    func loadData(with request: URLRequest,
                  didReceiveData: @escaping (Data, URLResponse) -> Void,
                  completion: @escaping (Error?) -> Void) -> any Cancellable {
        let box = TaskBox()
        // 调试：启动参数 -EHDisableImages YES 时不加载任何图片（用于截图/自动化测试）
        if UserDefaults.standard.bool(forKey: "EHDisableImages") {
            completion(URLError(.cancelled))
            return box
        }
        guard let url = request.url else {
            completion(URLError(.badURL))
            return box
        }
        // 本地文件直接读
        if url.isFileURL {
            do {
                let data = try Data(contentsOf: url)
                didReceiveData(data, URLResponse(url: url, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil))
                completion(nil)
            } catch {
                completion(error)
            }
            return box
        }
        guard let client = clientProvider() else {
            completion(URLError(.notConnectedToInternet))
            return box
        }
        let referer = request.value(forHTTPHeaderField: "Referer")
        box.task = Task {
            do {
                var req = client.makeRequest(url, referer: referer)
                req.timeout = client.config.imageTimeout
                req.followRedirects = true
                let resp = try await client.execute(req, validate: false)
                guard (200..<300).contains(resp.status) else {
                    completion(EhError.http(status: resp.status))
                    return
                }
                var fields: [String: String] = [:]
                for f in resp.headers { fields[f.name] = f.value }
                let urlResponse = HTTPURLResponse(url: resp.url, statusCode: resp.status, httpVersion: "HTTP/1.1", headerFields: fields)
                    ?? URLResponse(url: resp.url, mimeType: nil, expectedContentLength: resp.body.count, textEncodingName: nil)
                didReceiveData(resp.body, urlResponse)
                completion(nil)
            } catch {
                completion(error)
            }
        }
        return box
    }
}

/// 全局图片管线
enum AppImagePipeline {
    nonisolated(unsafe) private static var client: EhHTTPClient?

    static func configure(client: EhHTTPClient) {
        Self.client = client
        let loader = EhDataLoader(clientProvider: { AppImagePipeline.client })
        var config = ImagePipeline.Configuration.withDataCache(name: "com.xjs.ehviewer.thumbs", sizeLimit: 300 * 1024 * 1024)
        config.dataLoader = loader
        config.isProgressiveDecodingEnabled = false
        ImagePipeline.shared = ImagePipeline(configuration: config)
    }

    static func clearCaches() {
        ImagePipeline.shared.cache.removeAll()
    }
}

/// 雪碧图预览裁剪
struct SpriteCropProcessor: ImageProcessing, Hashable {
    let x: Int, y: Int, width: Int, height: Int

    var identifier: String { "eh.sprite.\(x).\(y).\(width).\(height)" }

    func process(_ image: PlatformImage) -> PlatformImage? {
        guard let cg = image.cgImage else { return image }
        // 站点给出的裁剪坐标基于原始像素
        let rect = CGRect(x: x, y: y, width: width, height: height)
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !rect.isNull, rect.width > 0, rect.height > 0, let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}

extension ImageRequest {
    /// 带 Referer 的图片请求
    static func eh(_ urlString: String?, referer: String? = nil, processors: [any ImageProcessing] = []) -> ImageRequest? {
        guard let s = urlString, let url = URL(string: s) else { return nil }
        var r = URLRequest(url: url)
        if let referer { r.setValue(referer, forHTTPHeaderField: "Referer") }
        return ImageRequest(urlRequest: r, processors: processors)
    }
}
