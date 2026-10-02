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
            debugLog("CACHE HIT | key=\(key) | cacheCount=\(cache.countLimit)")
            completeOnMain(completion, image: cachedImage)
            return
        }

        debugLog("CACHE MISS | key=\(key)")

        var shouldDecode = false
        var waitingCount = 0

        lock.lock()
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            waitingCount = inFlight[key]?.count ?? 0
        } else {
            inFlight[key] = [completion]
            shouldDecode = true
        }
        lock.unlock()

        if !shouldDecode {
            debugLog("IN-FLIGHT HIT | key=\(key) | waitingCallbacks=\(waitingCount)")
            return
        }

        debugLog("DECODE QUEUED | key=\(key) | qos=utility")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let start = CFAbsoluteTimeGetCurrent()

            debugLog("DECODE START | key=\(key) | mainThread=\(Thread.isMainThread)")

            let image = UIImage(
                blurHash: blurHash,
                size: size,
                punch: punch
            )

            let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let result = image == nil ? "FAILED" : "SUCCESS"

            debugLog(
                String(
                    format: "DECODE END | key=%@ | result=%@ | duration=%.2fms",
                    key,
                    result,
                    durationMs
                )
            )

            guard let self else {
                self?.completeOnMain(completion, image: image)
                return
            }

            self.finish(key: key, image: image)
        }
    }

    func removeAll() {
        cache.removeAllObjects()
        debugLog("CACHE CLEARED | BlurHash cache removed")
    }

    private func cacheKey(
        for blurHash: String,
        size: CGSize,
        punch: Float
    ) -> String {
        "\(blurHash)|\(Int(size.width))x\(Int(size.height))|\(punch)"
    }

    private func finish(
        key: String,
        image: UIImage?
    ) {
        if let image {
            let cost = imageCost(image)

            cache.setObject(
                image,
                forKey: key as NSString,
                cost: cost
            )

            debugLog(
                String(
                    format: "CACHE STORE | key=%@ | cost=%.2fKB",
                    key,
                    Double(cost) / 1024.0
                )
            )
        }

        lock.lock()
        let completions = inFlight.removeValue(forKey: key) ?? []
        lock.unlock()

        debugLog(
            "COMPLETE | key=\(key) | callbacks=\(completions.count) | cached=\(image != nil)"
        )

        for completion in completions {
            completeOnMain(completion, image: image)
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

    private func debugLog(_ message: String) {
#if DEBUG
        print("[TurboImage][BlurHash] \(message)")
#endif
    }
}
