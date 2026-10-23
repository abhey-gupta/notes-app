import Foundation
import Metal

/// `MTLHeap`-backed pool of tile textures (ARCHITECTURE.md §5.4). Every tile is the same size, so a
/// freed texture is simply reused; heaps grow in chunks of ``heapTiles`` up to ``capacity`` bytes.
///
/// Thread-safe (`@unchecked Sendable`: all mutable state is behind `lock`): the tile renderer
/// allocates on its queue, the main actor recycles and compacts.
/// Heaps track hazards, so passes in one command buffer and frames on one queue order themselves;
/// across queues, tiles are only published after their render completed and only recycled after the
/// frames that may sample them completed (``TiledContentRenderer``).
final class TexturePool: @unchecked Sendable {
    /// Textures per heap chunk (16 MiB).
    static let heapTiles = 16

    let device: any MTLDevice
    /// Bytes one tile texture takes in a heap (≈ 1 MiB).
    let tileBytes: Int
    private let align: Int
    private let lock = NSLock()
    private var state: State

    private struct State {
        var heaps: [any MTLHeap] = []
        var free: [any MTLTexture] = []
        var capacity: Int
        var heapBytes = 0
    }

    init(device: any MTLDevice, capacity: Int) {
        let sizeAndAlign = device.heapTextureSizeAndAlign(descriptor: Self.descriptor)
        let align = max(sizeAndAlign.align, 1)
        self.device = device
        self.align = align
        tileBytes = (sizeAndAlign.size + align - 1) / align * align
        state = State(capacity: capacity)
    }

    /// Private BGRA8 render target, `tilePixels` square.
    private static var descriptor: MTLTextureDescriptor {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: GPUContext.pixelFormat,
            width: TileGrid.tilePixels,
            height: TileGrid.tilePixels,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        return desc
    }

    /// Bytes reserved by heaps (what the pool costs).
    var allocatedBytes: Int {
        withLock { $0.heapBytes }
    }

    /// Free textures ready for reuse.
    var freeCount: Int {
        withLock { $0.free.count }
    }

    /// Most heap bytes the pool may reserve; lowering it never frees memory by itself (see ``compact(keeping:on:)``).
    var capacity: Int {
        get { withLock { $0.capacity } }
        set { withLock { $0.capacity = newValue } }
    }

    /// A tile texture, or `nil` if the pool is at capacity.
    func allocate() -> (any MTLTexture)? {
        withLock { s in
            if let texture = s.free.popLast() {
                return texture
            }
            let descriptor = Self.descriptor
            for heap in s.heaps where heap.maxAvailableSize(alignment: align) >= tileBytes {
                if let texture = heap.makeTexture(descriptor: descriptor) {
                    return label(texture)
                }
            }
            let tiles = min(Self.heapTiles, (s.capacity - s.heapBytes) / tileBytes)
            guard tiles > 0, let heap = makeHeap(tiles: tiles) else { return nil }
            s.heaps.append(heap)
            s.heapBytes += heap.size
            return heap.makeTexture(descriptor: descriptor).map(label)
        }
    }

    /// Returns textures for reuse (callers guarantee no GPU work still uses them). Textures from heaps
    /// the pool no longer owns (dropped by ``compact(keeping:on:)``) are released instead.
    func recycle(_ textures: [any MTLTexture]) {
        guard !textures.isEmpty else { return }
        withLock { s in
            for texture in textures where Self.owns(s, texture) {
                s.free.append(texture)
            }
        }
    }

    /// Whether `texture` lives in one of the pool's heaps.
    func owns(_ texture: any MTLTexture) -> Bool {
        withLock { Self.owns($0, texture) }
    }

    /// Releases heaps whose every texture is on the free list. Returns the bytes released.
    @discardableResult
    func trim() -> Int {
        withLock { s in
            var freeByHeap: [ObjectIdentifier: Int] = [:]
            for texture in s.free {
                if let heap = texture.heap {
                    freeByHeap[ObjectIdentifier(heap), default: 0] += 1
                }
            }
            let drop = Set(s.heaps.filter { heap in
                let free = freeByHeap[ObjectIdentifier(heap)] ?? 0
                return free > 0 && free * tileBytes >= heap.usedSize
            }.map(ObjectIdentifier.init))
            guard !drop.isEmpty else { return 0 }
            s.free.removeAll { $0.heap.map { drop.contains(ObjectIdentifier($0)) } ?? false }
            let released = s.heaps.filter { drop.contains(ObjectIdentifier($0)) }.reduce(0) { $0 + $1.size }
            s.heaps.removeAll { drop.contains(ObjectIdentifier($0)) }
            s.heapBytes -= released
            return released
        }
    }

    /// Moves `survivors` into one heap sized for exactly them (blit on `queue`, ordered before later
    /// frames on it) and drops every other heap and the free list, so the memory really goes back to
    /// the system. Returns the new textures in order; `nil` (nothing changed) if allocation failed.
    func compact(keeping survivors: [any MTLTexture], on queue: any MTLCommandQueue) -> [any MTLTexture]? {
        withLock { s in
            var moved: [any MTLTexture] = []
            var heap: (any MTLHeap)?
            if !survivors.isEmpty {
                let descriptor = Self.descriptor
                guard let fresh = makeHeap(tiles: survivors.count),
                      let commandBuffer = queue.makeCommandBuffer(),
                      let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
                for old in survivors {
                    guard let texture = fresh.makeTexture(descriptor: descriptor) else {
                        blit.endEncoding()
                        return nil
                    }
                    blit.copy(from: old, to: label(texture))
                    moved.append(texture)
                }
                blit.endEncoding()
                commandBuffer.label = "ink.tiles.compact"
                commandBuffer.commit()
                heap = fresh
            }
            s.free.removeAll()
            s.heaps = heap.map { [$0] } ?? []
            s.heapBytes = heap?.size ?? 0
            return moved
        }
    }

    private func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    private static func owns(_ s: State, _ texture: any MTLTexture) -> Bool {
        guard let heap = texture.heap else { return false }
        return s.heaps.contains { $0 === heap }
    }

    private func makeHeap(tiles: Int) -> (any MTLHeap)? {
        let desc = MTLHeapDescriptor()
        desc.storageMode = .private
        desc.hazardTrackingMode = .tracked
        desc.size = tiles * tileBytes
        let heap = device.makeHeap(descriptor: desc)
        heap?.label = "ink.tiles.heap"
        return heap
    }

    private func label(_ texture: any MTLTexture) -> any MTLTexture {
        texture.label = "ink.tile"
        return texture
    }
}
