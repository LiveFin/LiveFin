//
//  ImageCache.swift
//  LiveFin
//
//  Created by KPGamingz on 6/12/25.
//

#if canImport(UIKit)
import Foundation
import UIKit
import CryptoKit
import SwiftUI

final class ImageCacheManager {
    static let shared = ImageCacheManager()

    private let memory = NSCache<NSURL, UIImage>()
    private let ioQueue = DispatchQueue(label: "ImageCacheManager.io")

    // Disk cache location
    private let diskDir: URL

    // Default time-to-live for disk entries (in seconds)
    // Channel logos rarely change; 30 days is a safe, long-lived default.
    private let diskTTL: TimeInterval = 30 * 24 * 3600

    private init() {
        let fm = FileManager.default
        let base = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base?.appendingPathComponent("ChannelImagesCache", isDirectory: true)
        if let dir = dir {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            self.diskDir = dir
        } else {
            // Fallback to temporary directory if caches unavailable
            self.diskDir = fm.temporaryDirectory.appendingPathComponent("ChannelImagesCache", isDirectory: true)
            if !fm.fileExists(atPath: self.diskDir.path) {
                try? fm.createDirectory(at: self.diskDir, withIntermediateDirectories: true)
            }
        }
        memory.countLimit = 512
    }

    func imageIfCached(for url: URL) -> UIImage? {
        if let img = memory.object(forKey: url as NSURL) {
            return img
        }
        if let img = loadFromDiskIfFresh(url: url) {
            memory.setObject(img, forKey: url as NSURL)
            return img
        }
        return nil
    }

    func load(_ url: URL, session: URLSession = .shared, completion: @escaping (UIImage?) -> Void) {
        // First, try caches synchronously
        if let cached = imageIfCached(for: url) {
            DispatchQueue.main.async { completion(cached) }
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, let data = data, let image = UIImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.memory.setObject(image, forKey: url as NSURL)
            self.storeToDisk(data: data, for: url)
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }

    private func storeToDisk(data: Data, for url: URL) {
        ioQueue.async {
            let path = self.pathForURL(url)
            do {
                try data.write(to: path, options: [.atomic])
            } catch {
            }
        }
    }

    private func loadFromDiskIfFresh(url: URL) -> UIImage? {
        let fm = FileManager.default
        let path = pathForURL(url)
        guard fm.fileExists(atPath: path.path) else { return nil }
        do {
            let attrs = try fm.attributesOfItem(atPath: path.path)
            if let mod = attrs[.modificationDate] as? Date {
                if Date().timeIntervalSince(mod) > diskTTL {
                    try? fm.removeItem(at: path)
                    return nil
                }
            }
            let data = try Data(contentsOf: path)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }

    private func pathForURL(_ url: URL) -> URL {
        let key = sha256(url.absoluteString)
        return diskDir.appendingPathComponent(key).appendingPathExtension("bin")
    }

    private func sha256(_ s: String) -> String {
        let d = Data(s.utf8)
        let hash = SHA256.hash(data: d)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - SwiftUI Bridge: CachedAsyncImage
/// A direct drop-in replacement for SwiftUI's `AsyncImage` that supports disk and memory caching via `ImageCacheManager`.
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    @State private var uiImage: UIImage? = nil
    @State private var hasFailed = false
    @State private var isLoading = false
    
    let content: (AsyncImagePhase) -> Content
    
    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }
    
    var body: some View {
        Group {
            if let uiImage = uiImage {
                content(.success(Image(uiImage: uiImage)))
            } else if hasFailed {
                content(.failure(URLError(.cannotDecodeContentData)))
            } else {
                content(.empty)
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }
    
    private func loadImage() async {
        guard let url = url else {
            self.hasFailed = true
            return
        }
        
        // 1. Try memory/disk cache synchronously first to prevent flickering placeholders
        if let cached = ImageCacheManager.shared.imageIfCached(for: url) {
            self.uiImage = cached
            self.hasFailed = false
            return
        }
        
        // 2. Fetch asynchronously if not cached
        self.isLoading = true
        await withCheckedContinuation { continuation in
            ImageCacheManager.shared.load(url) { image in
                if let image = image {
                    self.uiImage = image
                    self.hasFailed = false
                } else {
                    self.uiImage = nil
                    self.hasFailed = true
                }
                self.isLoading = false
                continuation.resume()
            }
        }
    }
}
#endif
