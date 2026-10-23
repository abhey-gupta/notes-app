import Dispatch
import InkGeometry
import Metal

/// Per-frame vertex upload for live, pending-highlighter and overlay geometry: three shared buffers
/// used round-robin, gated by a semaphore so the CPU never overwrites a buffer the GPU is still reading.
@MainActor
final class FrameBufferRing {
    static let slotCount = 3

    private let device: any MTLDevice
    private var buffers: [(any MTLBuffer)?] = Array(repeating: nil, count: FrameBufferRing.slotCount)
    private var slot = 0
    private let inFlight = DispatchSemaphore(value: FrameBufferRing.slotCount)
    private var isHoldingSlot = false

    init(device: any MTLDevice) {
        self.device = device
    }

    /// Uploads `meshes` into the next free slot (waits if all three are in flight) and returns the
    /// buffer plus each mesh's byte offset. Call ``finish(_:)`` with the frame's command buffer after.
    func upload(_ meshes: [[StrokeVertex]]) -> (buffer: any MTLBuffer, offsets: [Int])? {
        let stride = MemoryLayout<StrokeVertex>.stride
        let length = meshes.reduce(0) { $0 + $1.count } * stride
        guard length > 0 else { return nil }
        inFlight.wait()
        slot = (slot + 1) % Self.slotCount
        if (buffers[slot]?.length ?? 0) < length {
            // Grow geometrically so a long stroke reallocates a handful of times, not every event.
            buffers[slot] = device.makeBuffer(length: max(length * 3 / 2, 64 * 1024), options: .storageModeShared)
            buffers[slot]?.label = "ink.frame.\(slot)"
        }
        guard let buffer = buffers[slot] else {
            inFlight.signal()
            return nil
        }
        var offsets: [Int] = []
        var offset = 0
        let base = buffer.contents()
        for mesh in meshes {
            offsets.append(offset)
            mesh.withUnsafeBytes { raw in
                if let src = raw.baseAddress {
                    (base + offset).copyMemory(from: src, byteCount: raw.count)
                }
            }
            offset += mesh.count * stride
        }
        isHoldingSlot = true
        return (buffer, offsets)
    }

    /// Releases the slot taken by the last ``upload(_:)`` once `commandBuffer` completes, or now if
    /// the frame was abandoned (`nil`).
    func finish(_ commandBuffer: (any MTLCommandBuffer)?) {
        guard isHoldingSlot else { return }
        isHoldingSlot = false
        let inFlight = inFlight
        if let commandBuffer {
            commandBuffer.addCompletedHandler { _ in inFlight.signal() }
        } else {
            inFlight.signal()
        }
    }
}
