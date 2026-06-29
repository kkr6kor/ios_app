import CoreLocation

/// A single guidance step from the router.
struct NavStep {
    let location: CLLocationCoordinate2D
    let type: String          // OSRM maneuver type (turn, merge, roundabout, arrive…)
    let modifier: String      // left / right / slight left …
    let name: String          // road name
    let distanceM: Double

    var instruction: String { ManeuverText.make(type: type, modifier: modifier, name: name) }
}

/// A computed route: full geometry + steps + totals.
struct NavRoute {
    let coordinates: [CLLocationCoordinate2D]
    let steps: [NavStep]
    let totalDistanceM: Double
    let totalDurationS: Double
}

/// Human-readable instruction text built from OSRM maneuver fields.
enum ManeuverText {
    static func make(type: String, modifier: String, name: String) -> String {
        let onto = name.isEmpty ? "" : " onto \(name)"
        switch type {
        case "depart":            return "Head out\(onto)"
        case "arrive":            return "Arrive at destination"
        case "turn":              return "Turn \(modifier)\(onto)"
        case "roundabout", "rotary": return "Take the roundabout\(onto)"
        case "merge":             return "Merge \(modifier)\(onto)"
        case "fork":              return "Keep \(modifier)\(onto)"
        case "on ramp", "off ramp": return "Take the ramp \(modifier)\(onto)"
        case "end of road":       return "Turn \(modifier)\(onto)"
        case "continue", "new name": return "Continue\(onto)"
        default:                  return modifier.isEmpty ? "Continue\(onto)" : "\(modifier.capitalized)\(onto)"
        }
    }
}

/// Best-effort OSRM maneuver → dash glyph code. Only `continue` (0x0B) is confirmed
/// on the wire; the rest are unverified, so they fall back to it. The on-dash arrow
/// drawn by `NavRenderer` is the reliable visual cue until the glyphs are captured.
enum ManeuverGlyph {
    static func code(type: String, modifier: String) -> Int {
        return DashCommands.navManeuverContinue   // 0x0B — TODO: map turn glyphs from a dash capture
    }
}
