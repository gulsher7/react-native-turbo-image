import UIKit

final class BlurHashImageCache {
    static let shared = BlurHashImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inFlight: [String: [(UIImage?) -> Void]] = [:]

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 4 * 1024 * 1024
    }

    func image(
        for blurHash: String,
        size: CGSize = .init(width: 32, height: 32),
        punch: Float = 1,
        completion: @escaping (UIImage?) -> Void
    ) {
        let key = cacheKey(for: blurHash, size: size, punch: punch)

        if let cachedImage = cache.object(forKey: key as NSString) {
            completion(cachedImage)
            return
        }

        var shouldDecode = false

        lock.lock()
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
        } else {
            inFlight[key] = [completion]
            shouldDecode = true
        }
        lock.unlock()

        guard shouldDecode else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let image = UIImage(
                blurHash: blurHash,
                size: size,
                punch: punch
            )

            guard let self else {
                completion(image)
                return
            }

            self.finish(key: key, image: image)
        }
    }

    func removeAll() {
        lock.lock()
        inFlight.removeAll()
        lock.unlock()

        cache.removeAllObjects()
    }

    private func cacheKey(for blurHash: String, size: CGSize, punch: Float) -> String {
        "(blurHash)|\(Int(size.width))x\(Int(size.height))|\(punch)"
    }

    private func finish(key: String, image: UIImage?) {
        if let image {
            let cost = imageCost(image)
            cache.setObject(image, forKey: key as NSString, cost: cost)
        }

        lock.lock()
        let completions = inFlight.removeValue(forKey: key) ?? []
        lock.unlock()

        for completion in completions {
            completion(image)
        }
    }

    private func imageCost(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
