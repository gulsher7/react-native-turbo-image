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
        let key = cacheKey(
            for: blurHash,
            size: size,
            punch: punch
        )

        // Return cached image immediately.
        if let cachedImage = cache.object(forKey: key as NSString) {
            completeOnMain(
                completion,
                image: cachedImage
            )
            return
        }

        var shouldDecode = false

        lock.lock()

        if inFlight[key] != nil {
            // A decode for this BlurHash is already in progress.
            // Wait for the existing decode instead of decoding again.
            inFlight[key]?.append(completion)
        } else {
            inFlight[key] = [completion]
            shouldDecode = true
        }

        lock.unlock()

        guard shouldDecode else {
            return
        }

        // Decode BlurHash in the background.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let image = UIImage(
                blurHash: blurHash,
                size: size,
                punch: punch
            )

            guard let self else {
                if Thread.isMainThread {
                    completion(image)
                } else {
                    DispatchQueue.main.async {
                        completion(image)
                    }
                }
                return
            }

            self.finish(
                key: key,
                image: image
            )
        }
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    private func cacheKey(
        for blurHash: String,
        size: CGSize,
        punch: Float
    ) -> String {
        "(blurHash)|(Int(size.width))x(Int(size.height))|(punch)"
    }

    private func finish(
        key: String,
        image: UIImage?
    ) {
        // Cache the decoded image.
        if let image {
            let cost = imageCost(image)

            cache.setObject(
                image,
                forKey: key as NSString,
                cost: cost
            )
        }

        // Get all requests waiting for this BlurHash.
        lock.lock()

        let completions = inFlight.removeValue(forKey: key) ?? []

        lock.unlock()

        // Complete all requests on the main thread.
        for completion in completions {
            completeOnMain(
                completion,
                image: image
            )
        }
    }

    private func completeOnMain(
        _ completion: @escaping (UIImage?) -> Void,
        image: UIImage?
    ) {
        if Thread.isMainThread {
            completion(image)
        } else {
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    private func imageCost(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else {
            return 0
        }

        return cgImage.bytesPerRow * cgImage.height
    }
}
