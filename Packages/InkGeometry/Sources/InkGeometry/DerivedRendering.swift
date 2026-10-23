import InkModel

public extension Stroke {
    /// The stored ``InkModel/Stroke/rendering``, or one derived from the pen profile for strokes that
    /// have none (v1 files, fixtures, other engines).
    var resolvedRendering: StrokeRendering {
        rendering ?? derivedRendering
    }

    /// Rendering derived from the pen profile: point size = base width × the profile's width scale at
    /// that sample (pressure and tilt, no speed term), square, opaque; the pen's ink; a seed taken from
    /// the stroke ID so every render of the stroke is the same.
    var derivedRendering: StrokeRendering {
        let profile = PenProfile(tool)
        let points = samples.map { s in
            let size = width * profile.widthScale(force: s.force, speed: 0, altitude: s.altitude)
            return PointRendering(width: size, height: size)
        }
        let u = id.uuid.uuid
        let seed = UInt32(u.12) << 24 | UInt32(u.13) << 16 | UInt32(u.14) << 8 | UInt32(u.15)
        return StrokeRendering(ink: StrokeRendering.Ink.for(tool), randomSeed: seed, points: points)
    }
}
