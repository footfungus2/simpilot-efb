import XCTest
@testable import SimPilotEFB

/// The WX layer and the ATIS & weather briefing: gunzip, aviationweather.gov parsers, the Lido category rule,
/// TAF conditions at a time and the plain-language decoder. Samples are trimmed copies of real AWC data.
final class WeatherTests: XCTestCase {
    // MARK: Gzip

    func testGunzipsAWCStyleFileWithFileName() throws {
        let data = try XCTUnwrap(Data(base64Encoded: WeatherSamples.gzipWithFileName))
        XCTAssertTrue(Gzip.isGzip(data))
        XCTAssertEqual(String(decoding: try Gzip.decompress(data), as: UTF8.self), WeatherSamples.gzipWithFileNameText)
    }

    func testGunzipSkipsEveryOptionalHeaderField() throws {
        // FEXTRA (whose data contains a zero byte), FNAME, FCOMMENT and FHCRC.
        let data = try XCTUnwrap(Data(base64Encoded: WeatherSamples.gzipAllHeaderFields))
        XCTAssertEqual(String(decoding: try Gzip.decompress(data), as: UTF8.self), "SimPilot")
    }

    func testGunzipSizesTheOutputFromTheTrailer() throws {
        let data = try XCTUnwrap(Data(base64Encoded: WeatherSamples.gzipLarge))
        let out = try Gzip.decompress(data)
        XCTAssertEqual(out.count, 200_000)
        XCTAssertEqual(String(decoding: out.prefix(12), as: UTF8.self), "METAR METAR ")
    }

    func testGunzipPassesPlainDataThroughAndRejectsDamagedFiles() throws {
        let plain = Data("raw_text,station_id\n".utf8)
        XCTAssertFalse(Gzip.isGzip(plain))
        XCTAssertEqual(try Gzip.decompressIfNeeded(plain), plain)

        let data = try XCTUnwrap(Data(base64Encoded: WeatherSamples.gzipWithFileName))
        XCTAssertThrowsError(try Gzip.decompress(data.prefix(15))) { XCTAssertEqual($0 as? Gzip.Failure, .truncated) }
        var wrongSize = data
        wrongSize[wrongSize.count - 4] ^= 0x01 // ISIZE no longer matches the inflated length
        XCTAssertThrowsError(try Gzip.decompress(wrongSize)) { XCTAssertEqual($0 as? Gzip.Failure, .corrupt) }
        var wrongChecksum = data
        wrongChecksum[wrongChecksum.count - 8] ^= 0x01
        XCTAssertThrowsError(try Gzip.decompress(wrongChecksum)) { XCTAssertEqual($0 as? Gzip.Failure, .corrupt) }
    }

    // MARK: METAR cache (CSV)

    func testCSVReaderHandlesQuotesEscapesAndLineEnds() {
        let rows = CSVReader.rows(Data("a,\"b \"\"c\"\", d\",e\r\n1,,3\n\"x\ny\",z".utf8))
        XCTAssertEqual(rows, [["a", "b \"c\", d", "e"], ["1", "", "3"], ["x\ny", "z"]])
    }

    func testParsesMetarCache() throws {
        let csv = ([WeatherSamples.metarHeader] + WeatherSamples.metarRows).joined(separator: "\n") + "\n"
        let reports = WeatherParser.metars(csv: Data(csv.utf8))
        // The row without coordinates and the truncated row are skipped.
        XCTAssertEqual(reports.map(\.icao), ["MRPV", "KCVO", "ENWV", "MWCB", "KIKW", "KJKA", "KANJ"])
        let byId = Dictionary(uniqueKeysWithValues: reports.map { ($0.icao, $0) })

        let mrpv = try XCTUnwrap(byId["MRPV"])
        XCTAssertEqual(mrpv.raw, "METAR MRPV 241400Z 09013G23KT 9999 FEW030 23/14 A3005 NOSIG")
        XCTAssertEqual(mrpv.lat, 9.957, accuracy: 1e-9)
        XCTAssertEqual(mrpv.lon, -84.141, accuracy: 1e-9)
        XCTAssertEqual(mrpv.observed, WeatherParser.date("2026-10-24T12:56:39Z"))
        XCTAssertEqual(mrpv.conditions.windDirDeg, 90)
        XCTAssertEqual(mrpv.conditions.windSpeedKt, 13)
        XCTAssertEqual(mrpv.conditions.windGustKt, 23)
        XCTAssertEqual(mrpv.conditions.visibilitySM, 6) // "6+"
        XCTAssertTrue(mrpv.conditions.visibilityOrMore)
        XCTAssertEqual(mrpv.conditions.clouds, [WxCloud(cover: "FEW", baseFt: 3000)])
        XCTAssertEqual(mrpv.temperatureC, 23)
        XCTAssertEqual(mrpv.dewpointC, 14)
        XCTAssertEqual(try XCTUnwrap(mrpv.altimeterHpa), 1017.6, accuracy: 0.1)
        XCTAssertEqual(mrpv.elevationM, 998)
        XCTAssertEqual(mrpv.category, .green)

        let kcvo = try XCTUnwrap(byId["KCVO"]) // 00000KT 1 1/2SM BR FEW002
        XCTAssertEqual(kcvo.conditions.windSpeedKt, 0)
        XCTAssertFalse(kcvo.conditions.windVariable)
        XCTAssertEqual(kcvo.conditions.visibilitySM, 1.5)
        XCTAssertFalse(kcvo.conditions.visibilityOrMore)
        XCTAssertEqual(kcvo.conditions.weather, "BR")
        XCTAssertNil(kcvo.temperatureC)
        XCTAssertNil(kcvo.conditions.ceilingFt)
        XCTAssertEqual(kcvo.category, .amber)

        // 9999NDV: AWC leaves the visibility empty; it's read from the raw group.
        let enwv = try XCTUnwrap(byId["ENWV"])
        XCTAssertEqual(try XCTUnwrap(enwv.conditions.visibilitySM), 9999 / 1609.344, accuracy: 1e-9)
        XCTAssertTrue(enwv.conditions.visibilityOrMore)
        XCTAssertEqual(enwv.conditions.ceilingFt, 1900)
        XCTAssertEqual(enwv.category, .green)

        // Quoted raw text with a comma inside.
        let mwcb = try XCTUnwrap(byId["MWCB"])
        XCTAssertTrue(mwcb.raw.hasSuffix("RMK VCSH-SE,S"))
        XCTAssertEqual(mwcb.conditions.weather, "VCSH")
        XCTAssertEqual(mwcb.conditions.clouds.map(\.cover), ["FEW", "SCT"])

        // VV000 / VV002: the sky-obscured layer carries the vertical visibility in feet.
        XCTAssertEqual(byId["KIKW"]?.conditions.ceilingFt, 0)
        XCTAssertEqual(byId["KIKW"]?.category, .red)
        XCTAssertEqual(byId["KANJ"]?.conditions.ceilingFt, 200)
        XCTAssertEqual(byId["KANJ"]?.category, .red)

        // VRB03KT is written as direction 0 with a speed.
        let kjka = try XCTUnwrap(byId["KJKA"])
        XCTAssertTrue(kjka.conditions.windVariable)
        XCTAssertNil(kjka.conditions.windDirDeg)
        XCTAssertEqual(kjka.conditions.windSpeedKt, 3)
        XCTAssertEqual(kjka.conditions.visibilitySM, 10) // "10+"
        XCTAssertTrue(kjka.conditions.visibilityOrMore)
    }

    func testMetarCacheWithoutHeaderGivesNothing() {
        XCTAssertTrue(WeatherParser.metars(csv: Data()).isEmpty)
        XCTAssertTrue(WeatherParser.metars(csv: Data("station_id,latitude\nEGSS,51.9\n".utf8)).isEmpty)
    }

    func testVisibilityFieldFormats() {
        XCTAssertTrue(WeatherParser.visibility("6+") == (6, true))
        XCTAssertTrue(WeatherParser.visibility("10+") == (10, true))
        XCTAssertTrue(WeatherParser.visibility("2.49") == (2.49, false))
        XCTAssertTrue(WeatherParser.visibility(NSNumber(value: 1.5)) == (1.5, false))
        XCTAssertTrue(WeatherParser.visibility("") == (nil, false))
        XCTAssertTrue(WeatherParser.visibility(nil) == (nil, false))
    }

    // MARK: Category rule

    func testCategoryRule() {
        // Green: visibility ≥ 5 km and ceiling ≥ 1500 ft; amber: ≥ 1.5 km / 500 ft; red below.
        XCTAssertEqual(WxCategory(visibilitySM: 6, ceilingFt: 3000), .green)
        XCTAssertEqual(WxCategory(visibilitySM: 3.2, ceilingFt: nil), .green) // 5.1 km
        XCTAssertEqual(WxCategory(visibilitySM: 3.0, ceilingFt: nil), .amber) // 4.8 km
        XCTAssertEqual(WxCategory(visibilitySM: 1.0, ceilingFt: nil), .amber) // 1.6 km
        XCTAssertEqual(WxCategory(visibilitySM: 0.9, ceilingFt: nil), .red) // 1.4 km
        XCTAssertEqual(WxCategory(visibilitySM: nil, ceilingFt: 1500), .green)
        XCTAssertEqual(WxCategory(visibilitySM: nil, ceilingFt: 1499), .amber)
        XCTAssertEqual(WxCategory(visibilitySM: nil, ceilingFt: 500), .amber)
        XCTAssertEqual(WxCategory(visibilitySM: nil, ceilingFt: 499), .red)
        XCTAssertEqual(WxCategory(visibilitySM: 10, ceilingFt: 400), .red)
        XCTAssertEqual(WxCategory(visibilitySM: nil, ceilingFt: nil), .unknown)
        XCTAssertEqual(WxCategory.green.worse(.amber), .amber)
        XCTAssertEqual(WxCategory.amber.worse(.unknown), .amber)
    }

    func testCeilingIsLowestBrokenOrOvercastLayerOrVerticalVisibility() {
        var c = WxConditions()
        c.visibilitySM = 6
        c.clouds = [WxCloud(cover: "FEW", baseFt: 300), WxCloud(cover: "BKN", baseFt: 1200), WxCloud(cover: "OVC", baseFt: 800)]
        XCTAssertEqual(c.ceilingFt, 800)
        XCTAssertEqual(c.category, .amber)
        c.clouds = [WxCloud(cover: "SCT", baseFt: 200)]
        XCTAssertNil(c.ceilingFt)
        XCTAssertEqual(c.category, .green)
        c.clouds = []
        c.verticalVisFt = 300
        XCTAssertEqual(c.ceilingFt, 300)
        XCTAssertEqual(c.category, .red)
    }

    // MARK: TAF

    func testTafJSONConditionsAtATime() throws {
        let taf = try XCTUnwrap(WeatherParser.taf(json: try json(WeatherSamples.egssTafJSON)))
        XCTAssertEqual(taf.icao, "EGSS")
        XCTAssertEqual(taf.issued, WeatherParser.date("2026-10-24T10:54:00Z"))
        XCTAssertEqual(taf.validFrom, utc("2026-10-24T12:00:00Z"))
        XCTAssertEqual(taf.validTo, utc("2026-10-25T18:00:00Z"))
        XCTAssertEqual(taf.groups.map(\.code), ["", "BECMG", "TEMPO", "PROB40 TEMPO", "PROB30 TEMPO", "BECMG", "TEMPO", "BECMG", "PROB40 TEMPO"])
        XCTAssertEqual(taf.groups.compactMap(\.rawIndex), Array(0..<9))
        XCTAssertEqual(taf.groups[1].becomingAt, utc("2026-10-24T15:00:00Z"))

        // 13:00: base forecast (BECMG still in progress); TEMPO 6000 RA BKN010 and PROB40 TEMPO 2500 +RA BKN007 are worse.
        let early = try XCTUnwrap(taf.forecast(at: utc("2026-10-24T13:00:00Z")))
        XCTAssertEqual(early.prevailing, .green)
        XCTAssertEqual(early.temporary, .amber)
        XCTAssertEqual(early.activeGroups, [0, 1, 2, 3])
        XCTAssertEqual(early.conditions.windSpeedKt, 12)

        // 16:00: the first BECMG is complete; the PROB30 TEMPO (wind only) is no worse.
        let afternoon = try XCTUnwrap(taf.forecast(at: utc("2026-10-24T16:00:00Z")))
        XCTAssertEqual(afternoon.conditions.windSpeedKt, 20)
        XCTAssertEqual(afternoon.conditions.windGustKt, 32)
        XCTAssertEqual(afternoon.prevailing, .green)
        XCTAssertEqual(afternoon.temporary, .amber)
        XCTAssertEqual(afternoon.activeGroups, [1, 2, 3, 4])

        // 23:30: the second BECMG is complete and every TEMPO has ended.
        let night = try XCTUnwrap(taf.forecast(at: utc("2026-10-24T23:30:00Z")))
        XCTAssertEqual(night.conditions.windDirDeg, 260)
        XCTAssertNil(night.temporary)
        XCTAssertEqual(night.activeGroups, [5])

        // Outside the validity there's no forecast (validTo is exclusive).
        XCTAssertNil(taf.forecast(at: utc("2026-10-24T11:59:00Z")))
        XCTAssertNil(taf.forecast(at: utc("2026-10-25T18:00:00Z")))
    }

    func testTafFromBecomingAndTemporaryGroups() throws {
        func conditions(vis: Double, ceiling: Int?) -> WxConditions {
            var c = WxConditions()
            c.visibilitySM = vis
            c.clouds = ceiling.map { [WxCloud(cover: "BKN", baseFt: $0)] } ?? [WxCloud(cover: "NSC")]
            return c
        }
        var cloudsOnly = WxConditions()
        cloudsOnly.clouds = [WxCloud(cover: "BKN", baseFt: 300)]
        var fog = WxConditions()
        fog.visibilitySM = 0.5
        let groups = [
            TafGroup(change: .base, from: utc("2026-10-24T06:00:00Z"), to: utc("2026-10-24T12:00:00Z"), conditions: conditions(vis: 6, ceiling: 4000)),
            TafGroup(change: .from, from: utc("2026-10-24T12:00:00Z"), to: utc("2026-10-24T18:00:00Z"), conditions: conditions(vis: 2, ceiling: 800)),
            TafGroup(change: .becoming, from: utc("2026-10-24T14:00:00Z"), to: utc("2026-10-24T18:00:00Z"),
                     becomingAt: utc("2026-10-24T16:00:00Z"), conditions: cloudsOnly),
            TafGroup(change: .temporary, from: utc("2026-10-24T08:00:00Z"), to: utc("2026-10-24T10:00:00Z"), conditions: fog),
            TafGroup(change: .from, from: utc("2026-10-24T18:00:00Z"), to: utc("2026-10-25T06:00:00Z"), conditions: conditions(vis: 6, ceiling: nil)),
        ]
        let taf = TafReport(icao: "EGXX", lat: 51, lon: 0, issued: nil, validFrom: utc("2026-10-24T06:00:00Z"),
                            validTo: utc("2026-10-25T06:00:00Z"), raw: "", groups: groups)
        // Sorted by start; at equal starts base/FM/BECMG come before TEMPO/PROB.
        XCTAssertEqual(taf.groups.map(\.change), [.base, .temporary, .from, .becoming, .from])

        func at(_ time: String) throws -> TafReport.Forecast { try XCTUnwrap(taf.forecast(at: utc(time))) }
        XCTAssertEqual(try at("2026-10-24T07:00:00Z").prevailing, .green)
        XCTAssertNil(try at("2026-10-24T07:00:00Z").temporary)
        XCTAssertEqual(try at("2026-10-24T09:00:00Z").prevailing, .green)
        XCTAssertEqual(try at("2026-10-24T09:00:00Z").temporary, .red) // TEMPO 0800
        XCTAssertEqual(try at("2026-10-24T13:00:00Z").prevailing, .amber) // FM1200
        XCTAssertEqual(try at("2026-10-24T13:00:00Z").activeGroups, [2])
        // While BECMG 14–16 is in progress the worse of before and after counts; afterwards it has replaced the clouds.
        XCTAssertEqual(try at("2026-10-24T15:00:00Z").prevailing, .red)
        XCTAssertEqual(try at("2026-10-24T15:00:00Z").conditions.ceilingFt, 800)
        XCTAssertEqual(try at("2026-10-24T17:00:00Z").prevailing, .red)
        XCTAssertEqual(try at("2026-10-24T17:00:00Z").conditions.ceilingFt, 300)
        XCTAssertEqual(try at("2026-10-24T17:00:00Z").conditions.visibilitySM, 2)
        // A later FM group replaces everything.
        XCTAssertEqual(try at("2026-10-24T19:00:00Z").prevailing, .green)
        XCTAssertEqual(try at("2026-10-24T19:00:00Z").activeGroups, [4])
    }

    func testParsesTafCacheXML() throws {
        let tafs = WeatherParser.tafs(xml: Data(WeatherSamples.tafXML.utf8))
        XCTAssertEqual(tafs.map(\.icao), ["KRAP", "EGXX"])

        let krap = tafs[0]
        XCTAssertTrue(krap.raw.hasPrefix("TAF KRAP 241257Z 2413/2512"))
        XCTAssertEqual(krap.issued, utc("2026-10-24T12:57:00Z"))
        XCTAssertEqual(krap.validFrom, utc("2026-10-24T13:00:00Z"))
        XCTAssertEqual(krap.lat, 44.0458, accuracy: 1e-9)
        // Groups come in reverse order in the file; they're sorted by start time.
        XCTAssertEqual(krap.groups.map(\.change), [.base, .from, .from, .from])
        XCTAssertEqual(krap.groups[0].conditions.windGustKt, 35)
        XCTAssertEqual(krap.groups[0].conditions.clouds.map(\.baseFt), [13000, 20000])
        XCTAssertTrue(krap.groups[3].conditions.windVariable)
        XCTAssertEqual(krap.groups[3].conditions.visibilitySM, 6)
        XCTAssertTrue(krap.groups[3].conditions.visibilityOrMore)
        XCTAssertEqual(try XCTUnwrap(krap.forecast(at: utc("2026-10-24T21:00:00Z"))).conditions.windDirDeg, 10)

        let egxx = tafs[1]
        XCTAssertEqual(egxx.groups.map(\.code), ["", "TEMPO", "BECMG", "PROB30"])
        XCTAssertEqual(egxx.groups[2].becomingAt, utc("2026-10-24T16:00:00Z"))
        XCTAssertEqual(egxx.groups[3].conditions.verticalVisFt, 100)
        XCTAssertEqual(egxx.groups[3].conditions.weather, "FG")
        XCTAssertEqual(try XCTUnwrap(egxx.forecast(at: utc("2026-10-24T13:00:00Z"))).temporary, .amber)
        XCTAssertEqual(try XCTUnwrap(egxx.forecast(at: utc("2026-10-24T15:00:00Z"))).prevailing, .red)
        XCTAssertEqual(try XCTUnwrap(egxx.forecast(at: utc("2026-10-24T19:00:00Z"))).activeGroups, [2, 3])
    }

    func testSplitsRawTafIntoGroupLines() {
        let lines = TafText.lines(WeatherSamples.egssRawTaf)
        XCTAssertEqual(lines.count, 9)
        XCTAssertEqual(lines[0], "TAF EGSS 241054Z 2412/2518 20012KT 9999 SCT030")
        XCTAssertEqual(lines[3], "PROB40 TEMPO 2412/2421 2500 +RA BKN007")
        XCTAssertEqual(TafText.lines("TAF KRAP 241257Z 2413/2512 34022G35KT P6SM BKN130 FM241500 34015G25KT P6SM FEW200"),
                       ["TAF KRAP 241257Z 2413/2512 34022G35KT P6SM BKN130", "FM241500 34015G25KT P6SM FEW200"])
    }

    // MARK: SIGMETs

    func testParsesSigmets() throws {
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(WeatherSamples.sigmetJSON.utf8)) as? [[String: Any]])
        let sigmets = WeatherParser.sigmets(json: list)
        XCTAssertEqual(sigmets.map(\.id), ["KZAK-TANGO 3-1792826400", "EDWW-A1-1792840000"]) // the 2-point area is dropped

        let tc = sigmets[0]
        XCTAssertEqual(tc.hazard, "TC")
        XCTAssertEqual(tc.levels, "TOP FL520")
        XCTAssertEqual(tc.movement, "Moving NNW at 4 kt")
        XCTAssertEqual(tc.change, "INTSF")
        // Across the antimeridian the ring stays continuous (longitudes past 180°) and closed.
        XCTAssertEqual(tc.rings.count, 1)
        XCTAssertEqual(tc.rings[0].map { $0[0] }, [179.5, 180.5, 180.5, 179.5, 179.5])
        let label = try XCTUnwrap(tc.labelPoint)
        XCTAssertEqual(abs(label[0]), 180, accuracy: 1e-6)
        XCTAssertEqual(label[1], 14.3, accuracy: 1e-6)

        let turb = sigmets[1]
        XCTAssertEqual(turb.levels, "FL150–FL380")
        XCTAssertEqual(turb.hazardName, "Turbulence")
        XCTAssertEqual(turb.qualifierName, "Severe")
        XCTAssertEqual(turb.movement, "Stationary")
        XCTAssertEqual(turb.rings.map(\.count), [4, 4])
        XCTAssertTrue(turb.isValid(at: Date(timeIntervalSince1970: 1_792_840_000)))
        XCTAssertFalse(turb.isValid(at: Date(timeIntervalSince1970: 1_792_850_000)))
    }

    // MARK: Decoder

    func testDecodesWeatherCodes() {
        XCTAssertEqual(WeatherDecoder.weather("-RA BR"), "Light rain, mist")
        XCTAssertEqual(WeatherDecoder.weather("+TSRA"), "Thunderstorm with heavy rain")
        XCTAssertEqual(WeatherDecoder.weather("VCSH"), "Showers in the vicinity")
        XCTAssertEqual(WeatherDecoder.weather("-SHRA"), "Light rain showers")
        XCTAssertEqual(WeatherDecoder.weather("FZFG"), "Freezing fog")
        XCTAssertEqual(WeatherDecoder.weather("BCFG"), "Fog patches")
        XCTAssertEqual(WeatherDecoder.weather("RASN"), "Rain and snow")
        XCTAssertEqual(WeatherDecoder.weather("TS"), "Thunderstorm")
        XCTAssertEqual(WeatherDecoder.weather("+FC"), "Tornado or waterspout")
        XCTAssertEqual(WeatherDecoder.weather("NSW"), "No significant weather")
        XCTAssertNil(WeatherDecoder.weather("//"))
        XCTAssertNil(WeatherDecoder.weather(nil))
    }

    func testDecodesWindVisibilityCloudsAndPressure() {
        var c = WxConditions()
        c.windSpeedKt = 0
        XCTAssertEqual(WeatherDecoder.wind(c), "Calm")
        c.windVariable = true
        c.windSpeedKt = 3
        XCTAssertEqual(WeatherDecoder.wind(c), "Variable, 3 kt")
        c.windVariable = false
        c.windDirDeg = 90
        c.windSpeedKt = 13
        c.windGustKt = 23
        XCTAssertEqual(WeatherDecoder.wind(c), "090° at 13 kt, gusts 23 kt")

        c.visibilitySM = 6
        c.visibilityOrMore = true
        XCTAssertEqual(WeatherDecoder.visibility(c, imperial: false), "10 km or more")
        XCTAssertEqual(WeatherDecoder.visibility(c, imperial: true), "6 SM or more")
        c.visibilityOrMore = false
        c.visibilitySM = 1.5
        XCTAssertEqual(WeatherDecoder.visibility(c, imperial: true), "1½ SM (2400 m)")
        c.visibilitySM = 3.73
        XCTAssertEqual(WeatherDecoder.visibility(c, imperial: false), "6 km")
        c.visibilitySM = 0.25
        XCTAssertEqual(WeatherDecoder.visibility(c, imperial: false), "400 m")

        c.clouds = [WxCloud(cover: "FEW", baseFt: 1600, type: "CB"), WxCloud(cover: "SCT", baseFt: 2000)]
        XCTAssertEqual(WeatherDecoder.clouds(c), "Few 1600 ft (cumulonimbus), scattered 2000 ft")
        c.clouds = [WxCloud(cover: "OVX", baseFt: 0)]
        XCTAssertEqual(WeatherDecoder.clouds(c), "Sky obscured, vertical visibility 0 ft")
        c.clouds = [WxCloud(cover: "CAVOK")]
        XCTAssertEqual(WeatherDecoder.clouds(c), "CAVOK: no cloud below 5000 ft, no CB, visibility 10 km or more")

        XCTAssertEqual(WeatherDecoder.pressure(1004, imperial: false), "1004 hPa (29.65 inHg)")
        XCTAssertEqual(WeatherDecoder.pressure(1025.1, imperial: true), "30.27 inHg (1025 hPa)")
        XCTAssertNil(WeatherDecoder.pressure(500, imperial: false))
        XCTAssertTrue(WeatherDecoder.usesImperial("KJFK"))
        XCTAssertFalse(WeatherDecoder.usesImperial("EGSS"))
    }

    func testDecodesTafGroupSummaryAndTitle() throws {
        let taf = try XCTUnwrap(WeatherParser.taf(json: try json(WeatherSamples.egssTafJSON)))
        let now = utc("2026-10-24T11:00:00Z")
        XCTAssertEqual(WeatherDecoder.summary(taf.groups[2].conditions, imperial: false), "6 km · Rain · Broken 1000 ft")
        XCTAssertEqual(WeatherDecoder.title(taf.groups[3], relativeTo: now), "40 % chance, temporarily 12:00Z – 21:00Z")
        XCTAssertEqual(WeatherDecoder.title(taf.groups[1], relativeTo: now), "Becoming 12:00Z – 15:00Z")
        XCTAssertEqual(WeatherDecoder.title(taf.groups[6], relativeTo: now), "Temporarily Sun 09:00Z – Sun 15:00Z")
    }

    // MARK: Helpers

    private func utc(_ s: String) -> Date {
        guard let date = WeatherParser.date(s) else {
            XCTFail("Bad date \(s)")
            return .distantPast
        }
        return date
    }

    private func json(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }
}
