import Foundation

/// Fenix A320 cockpit variables and commands, taken from the community HubHop/MobiFlight presets.
/// Commands are MSFS RPN snippets the bridge runs against the aircraft's L:vars.
/// Everything that might need correcting after a test in the sim lives in this file.
enum FenixA320 {
    // MARK: Command builders

    static func inc(_ v: String) -> String { "(L:\(v)) ++ (>L:\(v))" }
    static func dec(_ v: String) -> String { "(L:\(v)) -- (>L:\(v))" }
    static func set(_ v: String, _ n: Int) -> String { "\(n) (>L:\(v))" }

    /// Fenix momentary pushbuttons count presses: +1 on press, +1 on release (only if the count is odd).
    static func counterPress(_ v: String) -> (press: String, release: String) {
        (inc(v), "(L:\(v)) 2 % 1 == if{ (L:\(v)) ++ (>L:\(v)) }")
    }

    /// A few buttons are plain 1 while held, 0 when released.
    static func holdPress(_ v: String) -> (press: String, release: String) {
        (set(v, 1), set(v, 0))
    }

    // MARK: RMP

    struct RMP {
        let n: Int
        var active: String { "N_PED_RMP\(n)_ACTIVE" }
        var standby: String { "N_PED_RMP\(n)_STDBY" }
        var power: String { "S_PED_RMP\(n)_POWER" }
        var transfer: String { "S_PED_RMP\(n)_XFER" }
        var outer: String { "E_PED_RMP\(n)_OUTER" }
        var inner: String { "E_PED_RMP\(n)_INNER" }
        var selLight: String { "I_PED_RMP\(n)_SEL" }
        /// Comm keys: (label, switch var, light var, counter-style?)
        var comKeys: [(label: String, sw: String, light: String, counter: Bool)] {
            [("VHF1", "S_PED_RMP\(n)_VHF1", "I_PED_RMP\(n)_VHF1", true),
             ("VHF2", "S_PED_RMP\(n)_VHF2", "I_PED_RMP\(n)_VHF2", true),
             ("VHF3", "S_PED_RMP\(n)_VHF3", "I_PED_RMP\(n)_VHF3", true),
             ("HF1", "S_PED_RMP\(n)_HF1", "I_PED_RMP\(n)_HF1", false),
             ("HF2", "S_PED_RMP\(n)_HF2", "I_PED_RMP\(n)_HF2", false),
             ("AM", "S_PED_RMP\(n)_AM", "I_PED_RMP\(n)_AM", false)]
        }
        var navKeys: [(label: String, sw: String, light: String, counter: Bool)] {
            [("NAV", "S_PED_RMP\(n)_NAV", "I_PED_RMP\(n)_NAV", false),
             ("VOR", "S_PED_RMP\(n)_VOR", "I_PED_RMP\(n)_VOR", false),
             ("LS", "S_PED_RMP\(n)_ILS", "I_PED_RMP\(n)_ILS", true),
             ("GLS", "S_PED_RMP\(n)_MLS", "I_PED_RMP\(n)_MLS", false),
             ("ADF", "S_PED_RMP\(n)_ADF", "I_PED_RMP\(n)_ADF", false),
             ("BFO", "S_PED_RMP\(n)_BFO", "I_PED_RMP\(n)_BFO", false)]
        }
        var watched: [String] {
            [active, standby, power, selLight] + (comKeys + navKeys).map(\.light)
        }
    }

    static let rmp1 = RMP(n: 1)
    static let rmp2 = RMP(n: 2)

    /// RMP frequencies are stored in kHz (121800 → 121.800).
    static func frequency(_ v: Double?) -> String {
        guard let v, v > 0 else { return "" }
        return String(format: "%07.3f", v / 1000)
    }

    // MARK: ATC / TCAS

    enum ATC {
        static let code = "N_FREQ_XPDR_SELECTED"
        static let entered = "N_PED_XPDR_CHAR_DISPLAYED"
        static let fail = "I_XPDR_FAIL"
        static func digit(_ d: Int) -> String { "S_PED_ATC_\(d)" }
        static let clear = "S_PED_ATC_CLR"
        static let ident = "S_XPDR_IDENT"
        static let operation = "S_XPDR_OPERATION" // 0 STBY, 1 AUTO, 2 ON
        static let altReporting = "S_XPDR_ALTREPORTING" // 0 OFF, 1 ON
        static let system = "S_XPDR_ATC" // 0 = 1, 1 = 2
        static let tcasMode = "S_XPDR_MODE" // 0 STBY, 1 TA, 2 TA/RA
        static let traffic = "S_TCAS_RANGE" // 0 THRT, 1 ALL, 2 ABV, 3 BLW
        static let watched = [code, entered, fail, operation, altReporting, system, tcasMode, traffic]
    }

    // MARK: FCU

    enum FCU {
        static let speed = "N_FCU_SPEED", heading = "N_FCU_HEADING", altitude = "N_FCU_ALTITUDE", vs = "N_FCU_VS"
        static let speedDashed = "B_FCU_SPEED_DASHED", headingDashed = "B_FCU_HEADING_DASHED", vsDashed = "B_FCU_VERTICALSPEED_DASHED"
        static let speedManaged = "I_FCU_SPEED_MANAGED", headingManaged = "I_FCU_HEADING_MANAGED", altitudeManaged = "I_FCU_ALTITUDE_MANAGED"
        static let mach = "B_FCU_SPEED_MACH", trackFpa = "B_FCU_TRACK_FPA_MODE", power = "B_FCU_POWER"

        /// Knobs: (turn var, push/pull var). Push = decrement, pull = increment.
        static let speedKnob = ("E_FCU_SPEED", "S_FCU_SPEED")
        static let headingKnob = ("E_FCU_HEADING", "S_FCU_HEADING")
        static let altitudeKnob = ("E_FCU_ALTITUDE", "S_FCU_ALTITUDE")
        static let vsKnob = ("E_FCU_VS", "S_FCU_VERTICAL_SPEED")
        static let altitudeScale = "S_FCU_ALTITUDE_SCALE" // 0 = 100, 1 = 1000

        /// Pushbuttons: (label, switch var, light var or nil)
        static let buttons: [String: (sw: String, light: String?)] = [
            "AP1": ("S_FCU_AP1", "I_FCU_AP1"), "AP2": ("S_FCU_AP2", "I_FCU_AP2"), "A/THR": ("S_FCU_ATHR", "I_FCU_ATHR"),
            "LOC": ("S_FCU_LOC", "I_FCU_LOC"), "EXPED": ("S_FCU_EXPED", "I_FCU_EXPED"), "APPR": ("S_FCU_APPR", "I_FCU_APPR"),
            "SPD MACH": ("S_FCU_SPD_MACH", nil), "HDG V/S TRK FPA": ("S_FCU_HDGVS_TRKFPA", nil), "METRIC ALT": ("S_FCU_METRIC_ALT", nil),
        ]

        static var watched: [String] {
            [speed, heading, altitude, vs, speedDashed, headingDashed, vsDashed, speedManaged, headingManaged, altitudeManaged,
             mach, trackFpa, power, altitudeScale] + buttons.values.compactMap(\.light)
        }
    }

    // MARK: Lights and signs (overhead)

    struct Switch {
        let title: String
        let v: String
        let positions: [(label: String, value: Int)] // top to bottom, as on the panel
    }

    static let exteriorLights: [Switch] = [
        Switch(title: "STROBE", v: "S_OH_EXT_LT_STROBE", positions: [("ON", 2), ("AUTO", 1), ("OFF", 0)]),
        Switch(title: "BEACON", v: "S_OH_EXT_LT_BEACON", positions: [("ON", 1), ("OFF", 0)]),
        Switch(title: "WING", v: "S_OH_EXT_LT_WING", positions: [("ON", 1), ("OFF", 0)]),
        Switch(title: "NAV & LOGO", v: "S_OH_EXT_LT_NAV_LOGO", positions: [("2", 2), ("1", 1), ("OFF", 0)]),
        Switch(title: "RWY TURN OFF", v: "S_OH_EXT_LT_RWY_TURNOFF", positions: [("ON", 1), ("OFF", 0)]),
        Switch(title: "LAND L", v: "S_OH_EXT_LT_LANDING_L", positions: [("ON", 2), ("OFF", 1), ("RETRACT", 0)]),
        Switch(title: "LAND R", v: "S_OH_EXT_LT_LANDING_R", positions: [("ON", 2), ("OFF", 1), ("RETRACT", 0)]),
        Switch(title: "NOSE", v: "S_OH_EXT_LT_NOSE", positions: [("T.O.", 2), ("TAXI", 1), ("OFF", 0)]),
    ]

    static let signs: [Switch] = [
        Switch(title: "SEAT BELTS", v: "S_OH_SIGNS", positions: [("ON", 1), ("OFF", 0)]),
        Switch(title: "NO SMOKING", v: "S_OH_SIGNS_SMOKING", positions: [("ON", 2), ("AUTO", 1), ("OFF", 0)]),
        Switch(title: "EMER EXIT LT", v: "S_OH_INT_LT_EMER", positions: [("ON", 2), ("ARM", 1), ("OFF", 0)]),
    ]

    static let interiorLights: [Switch] = [
        Switch(title: "DOME", v: "S_OH_INT_LT_DOME", positions: [("BRT", 2), ("DIM", 1), ("OFF", 0)]),
        Switch(title: "ANN LT", v: "S_OH_IN_LT_ANN_LT", positions: [("TEST", 2), ("BRT", 1), ("DIM", 0)]),
    ]

    static var lightsWatched: [String] { (exteriorLights + signs + interiorLights).map(\.v) }

    static var allWatched: [String] {
        rmp1.watched + rmp2.watched + ATC.watched + FCU.watched + lightsWatched
    }
}
