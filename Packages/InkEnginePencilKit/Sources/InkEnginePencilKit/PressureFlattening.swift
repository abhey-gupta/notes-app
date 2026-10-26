import InkModel

/// Pressure sensitivity off (#123). PencilKit has no inking option to ignore force, so a captured stroke
/// is flattened on lift: every sample gets ``InkModel/Sample/neutralForce`` and every point the size
/// (and watercolor wash) the ink paints at neutral force, so the stroke keeps one width.
///
/// The neutral size comes from the stroke itself: a least-squares line of point size against force,
/// read at neutral force. That keeps PencilKit's own width for the tool (no jump on lift beyond losing
/// the pressure swell) without modelling its force curve per ink. Strokes with (nearly) one force use
/// the median size.
public extension Stroke {
    /// This stroke at neutral pressure and constant point size (same id, ink, seed, path, tilt).
    var pressureFlattened: Stroke {
        guard !samples.isEmpty else { return self }
        let forces = samples.map(\.force)
        let flat = samples.map { s in
            Sample(x: s.x, y: s.y, force: Sample.neutralForce, altitude: s.altitude, azimuth: s.azimuth, t: s.t)
        }
        var flattened = rendering
        if let points = rendering?.points {
            let width = Self.neutral(points.map { Double($0.width) }, forces: forces)
            let height = Self.neutral(points.map { Double($0.height) }, forces: forces)
            let wash = Self.neutral(points.map(\.secondaryScale), forces: forces)
            flattened?.points = points.map { point in
                var point = point
                point.width = Float(width)
                point.height = Float(height)
                point.secondaryScale = wash
                return point
            }
        }
        return Stroke(id: id, tool: tool, color: color, width: width, samples: flat, rendering: flattened)
    }

    /// `values` read at neutral force off their least-squares line against `forces`, kept within
    /// half to twice their median; the median when force barely varies.
    private static func neutral(_ values: [Double], forces: [Float]) -> Double {
        let median = values.sorted()[values.count / 2]
        let x = forces.map(Double.init)
        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = values.reduce(0, +) / n
        let sxx = x.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        guard sxx / n > 1e-6 else { return median }
        let sxy = zip(x, values).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let value = meanY + sxy / sxx * (Double(Sample.neutralForce) - meanX)
        guard value.isFinite else { return median }
        return min(max(value, median / 2), median * 2)
    }
}
