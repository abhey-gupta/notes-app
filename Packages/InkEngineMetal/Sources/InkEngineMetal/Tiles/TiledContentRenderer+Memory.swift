import CoreGraphics
import Foundation
import QuartzCore

extension TiledContentRenderer {
    // MARK: Zoom

    /// The bucket to plan with: the zoom's own, or while zooming no sharper than at gesture start.
    func bucket(forZoom zoom: CGFloat, now: CFTimeInterval) -> ZoomBucket {
        let natural = ZoomBucket.forZoom(zoom)
        if !usesExplicitGestures, let last = lastZoom, abs(last - zoom) > 1e-9 {
            frozenBucket = frozenBucket ?? targetBucket ?? natural
            lastZoomChange = now
            scheduleZoomSettle()
        }
        lastZoom = zoom
        let zooming = gestureActive || (!usesExplicitGestures && now - lastZoomChange < configuration.zoomSettleDelay)
        if zooming, let frozen = frozenBucket {
            return min(frozen, natural)
        }
        frozenBucket = nil
        return natural
    }

    private func scheduleZoomSettle() {
        settleTask?.cancel()
        let delay = configuration.zoomSettleDelay
        guard delay > 0 else { return }
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.005))
            guard !Task.isCancelled, let self else { return }
            needsPlan = true
            onNeedsFrame?()
        }
    }

    // MARK: Memory

    /// The budget now (halved for a while after a memory warning, but never below twice the visible
    /// tiles: stale visible tiles re-render into staging before they swap in, so less would stall them).
    func effectiveBudget(now: CFTimeInterval = CACurrentMediaTime()) -> Int {
        if let pressureBudget, now < pressureUntil {
            return min(max(pressureBudget, 2 * visibleKeys.count * pool.tileBytes), configuration.budget)
        }
        pressureBudget = nil
        return configuration.budget
    }

    /// Keeps only visible tiles (at most half of the pool), compacts them into one heap and halves the
    /// budget for ``Configuration/memoryPressureDuration``. Visible tiles keep showing; the rest come
    /// back from the fallback chain and re-render within the lower budget.
    func handleMemoryWarning() {
        stats.memoryWarnings += 1
        let before = pool.allocatedBytes
        let target = before / 2
        let keep = Array(visibleKeys.filter { cache[$0] != nil }.prefix(target / pool.tileBytes))
        let keepSet = Set(keep)
        retiring += cache.removeAll { keepSet.contains($0) }
        retiring += staged.values.map(\.texture)
        staged.removeAll()
        renderer.submit([])
        let survivors = keep.compactMap { cache[$0]?.value }
        if let moved = pool.compact(keeping: survivors, on: gpu.frameQueue) {
            for (key, texture) in zip(keep, moved) {
                cache.insert(key, texture, bytes: pool.tileBytes, isStale: cache[key]?.isStale ?? false)
            }
        } else {
            Self.log.error("tile compaction failed; memory stays reserved until tiles are evicted")
        }
        pressureBudget = max(target, pool.tileBytes)
        pressureUntil = CACurrentMediaTime() + configuration.memoryPressureDuration
        pool.capacity = effectiveBudget()
        lastPlanKey = nil
        needsPlan = true
        onNeedsFrame?()
    }
}
