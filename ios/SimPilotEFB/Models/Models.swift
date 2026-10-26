import CoreLocation
import Foundation

// Wire types from the bridge. Keep in sync with bridge/src/types.ts and shared/protocol.md.

struct Ownship: Codable, Equatable {
    var lat: Double
    var lon: Double
    var altFt: Double
    var gsKt: Double
    var trkDeg: Double
    var hdgDeg: Double
    var vsFpm: Double
    var onGround: Bool
    var magVarDeg: Double
    var ts: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

struct BridgeStatus: Codable, Equatable {
    struct Sim: Codable, Equatable {
        var connected: Bool
        var aircraftTitle: String?
    }
    struct Link: Codable, Equatable {
        var connected: Bool
        var lastSeenMs: Double?
    }
    var sim: Sim
    var link: Link
}

struct ChartRect: Codable, Equatable {
    var upperLeft: [Double]
    var lowerRight: [Double]
    var orientation: Double
}

struct ChartProjection: Codable, Equatable {
    var standardParallel1: Double
    var standardParallel2: Double
    var centralMeridian: Double
}

struct ChartArea: Codable, Equatable {
    var layer: String
    var geoReferenced: Bool
    var chartRect: ChartRect
    var worldRect: ChartRect?
    var projection: ChartProjection?
    /// Straight, evenly spaced lat/lon grid (e.g. UK AIP charts): lon and lat map linearly onto x and y.
    /// Absent for Lido pages, which use `projection`.
    var linear: Bool? = nil
    /// Fitted Lambert georeference for scanned/rotated charts: chart = t + s·R(θ)·[u, −v] with (u, v) the
    /// unit-sphere Lambert conic of `projection`. Values: [tx, ty, s, θ (radians)].
    var similarity: [Double]? = nil
}

struct ChartMeta: Codable, Equatable, Identifiable, Hashable {
    var guid: String
    var type: String
    var name: String
    var runways: [String]
    var procedures: [String]
    var geoReferenced: Bool
    var pageCount: Int?
    var validFrom: Double?
    var validUntil: Double?

    var id: String { guid }
}

struct ChartCategory: Codable, Equatable {
    var name: String
    var charts: [ChartMeta]
}

struct ChartIndex: Codable, Equatable {
    var icao: String
    var provider: String
    var fetchedAt: Double
    var categories: [ChartCategory]
}

struct ChartPage: Codable, Equatable {
    var index: Int
    var width: Double
    var height: Double
    var geoReferenced: Bool
    var areas: [ChartArea]
    var image: String?
}

struct ChartDetail: Codable, Equatable {
    var chart: ChartMeta
    var pages: [ChartPage]
}

// MARK: - SimBrief OFP (normalized by the bridge)

struct OfpAirport: Codable, Equatable, Hashable {
    var icao: String
    var iata: String
    var name: String
    var lat: Double
    var lon: Double
    var elevFt: Double
    var planRwy: String
    var metar: String

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

struct OfpFix: Codable, Equatable {
    var ident: String
    var name: String
    var type: String
    var lat: Double
    var lon: Double
    var altFt: Double
    var airway: String
    var stage: String
    var isSidStar: Bool
    var legNm: Double
    var cumNm: Double
    var frequency: String

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

struct Ofp: Codable, Equatable {
    struct Aircraft: Codable, Equatable { var icao: String; var name: String; var reg: String }
    struct Times: Codable, Equatable { var schedOut: Double; var schedOff: Double; var schedOn: Double; var schedIn: Double; var eteSec: Double }
    struct Fuel: Codable, Equatable { var units: String; var ramp: Double; var takeoff: Double; var landing: Double; var minTakeoff: Double }

    var fetchedAt: Double
    var airac: String
    var callsign: String
    var aircraft: Aircraft
    var origin: OfpAirport
    var destination: OfpAirport
    var alternates: [OfpAirport]
    var route: String
    var distanceNm: Double
    var cruiseFl: Int
    var costIndex: String
    var times: Times
    var fuel: Fuel
    var navlog: [OfpFix]
    var ofpHtml: String
    var pdfUrl: String?
}

// MARK: - WebSocket envelope

enum BridgeMessage {
    case hello(BridgeStatus)
    case status(BridgeStatus)
    case ownship(Ownship)
    case chartsReady(icao: String)
    case chartsError(icao: String, message: String)
    case chartReady(icao: String, guid: String)
    case chartProgress(icao: String, guid: String, done: Int, total: Int)
    case chartError(icao: String, guid: String, message: String)
    case lvars([String: Double])
    case commandResult(id: String, ok: Bool, message: String?)

    private struct Envelope: Decodable { var t: String }
    private struct Hello: Decodable { var status: BridgeStatus }
    private struct Icao: Decodable { var icao: String }
    private struct ErrorMsg: Decodable { var icao: String; var message: String }
    private struct ChartRef: Decodable { var icao: String; var guid: String }
    private struct ChartProgressMsg: Decodable { var icao: String; var guid: String; var done: Int; var total: Int }
    private struct ChartErrorMsg: Decodable { var icao: String; var guid: String; var message: String }
    private struct LVarsMsg: Decodable { var values: [String: Double] }
    private struct ResultMsg: Decodable { var id: String; var ok: Bool; var message: String? }

    static func decode(_ data: Data) -> BridgeMessage? {
        let dec = JSONDecoder()
        guard let env = try? dec.decode(Envelope.self, from: data) else { return nil }
        switch env.t {
        case "hello": return (try? dec.decode(Hello.self, from: data)).map { .hello($0.status) }
        case "status": return (try? dec.decode(BridgeStatus.self, from: data)).map { .status($0) }
        case "ownship": return (try? dec.decode(Ownship.self, from: data)).map { .ownship($0) }
        case "chartsReady": return (try? dec.decode(Icao.self, from: data)).map { .chartsReady(icao: $0.icao) }
        case "chartsError": return (try? dec.decode(ErrorMsg.self, from: data)).map { .chartsError(icao: $0.icao, message: $0.message) }
        case "chartReady": return (try? dec.decode(ChartRef.self, from: data)).map { .chartReady(icao: $0.icao, guid: $0.guid) }
        case "chartProgress": return (try? dec.decode(ChartProgressMsg.self, from: data)).map { .chartProgress(icao: $0.icao, guid: $0.guid, done: $0.done, total: $0.total) }
        case "chartError": return (try? dec.decode(ChartErrorMsg.self, from: data)).map { .chartError(icao: $0.icao, guid: $0.guid, message: $0.message) }
        case "lvars": return (try? dec.decode(LVarsMsg.self, from: data)).map { .lvars($0.values) }
        case "commandResult": return (try? dec.decode(ResultMsg.self, from: data)).map { .commandResult(id: $0.id, ok: $0.ok, message: $0.message) }
        default: return nil
        }
    }
}
