import UIKit

final class BlurHashImageCache {
    static let shared = BlurHashImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inFlight: [String: [(UIImage?) -> Void]] = [:]

#if DEBUG
    private static let statsLock = NSLock()
    private static var requestCount = 0
    private static var hitCount = 0
    private static var missCount = 0
    private static var decodeCount = 0
#endif

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

        Self.recordRequest()

        if let cachedImage = cache.object(forKey: key as NSString) {
            Self.recordHit()
            Self.debugLog("CACHE HIT | key=\(key) | cacheLimit=\(cache.countLimit)")
            Self.completeOnMain(completion, image: cachedImage)
            return
        }

        Self.recordMiss()
        Self.recordMiss()
        Self.debugLog("CACHE MISS | key=\(key)")

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
            Self.debugLog("IN-FLIGHT HIT | key=\(key) | waitingCallbacks=\(waitingCount)")
            return
        }

        Self.recordDecode()
        Self.recordDecode()
        Self.debugLog("DECODE QUEUED | key=\(key) | qos=utility")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let start = CFAbsoluteTimeGetCurrent()

            Self.debugLog("DECODE START | key=\(key) | mainThread=\(Thread.isMainThread)")

            let image = UIImage(
                blurHash: blurHash,
                size: size,
                punch: punch
            )

            let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let result = image == nil ? "FAILED" : "SUCCESS"

            Self.debugLog(
                String(
                    format: "DECODE END | key=%@ | result=%@ | duration=%.2fms",
                    key,
                    result,
                    durationMs
                )
            )

            guard let self else {
                Self.completeOnMain(completion, image: image)
                return
            }

            self.finish(key: key, image: image)
        }
    }

    func removeAll() {
        cache.removeAllObjects()
        Self.debugLog("CACHE CLEARED | BlurHash cache removed")
        Self.debugStats()
    }

    private static func recordRequest() {
#if DEBUG
        lockStats.lock()
        requestCount += 1
        let shouldLog = requestCount % 50 == 0
        lockStats.unlock()
        if shouldLog {
            debugStats()
        }
#endif
    }

    private static func recordHit() {
#if DEBUG
        lockStats.lock()
        hitCount += 1
        lockStats.unlock()
#endif
    }

    private static func recordMiss() {
#if DEBUG
        lockStats.lock()
        missCount += 1
        lockStats.unlock()
#endif
    }

    private static func recordDecode() {
#if DEBUG
        lockStats.lock()
        decodeCount += 1
        lockStats.unlock()
#endif
    }

    private static let lockStats = NSLock()

    private static func debugStats() {
#if DEBUG
        lockStats.lock()
        let requests = requestCount
        let hits = hitCount
        let misses = missCount
        let decodes = decodeCount
        lockStats.unlock()

        let hitRate = requests > 0 ? (Double(hits) / Double(requests)) * 100 : 0
        debugLog(
            String(
                format: "STATS | requests=%d | hits=%d | misses=%d | decodes=%d | hitRate=%.2f%%",
                requests,
                hits,
                misses,
                decodes,
                hitRate
            )
        )
#endif
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

            Self.debugLog(
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

        Self.debugLog(
            "COMPLETE | key=\(key) | callbacks=\(completions.count) | cached=\(image != nil)"
        )

        for completion in completions {
            Self.completeOnMain(completion, image: image)
        }
    }

    private static func completeOnMain(
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

    private static func debugLog(_ message: String) {
#if DEBUG
        print("[TurboImage][BlurHash][PERF] \(message)")
#endif
    }
}
