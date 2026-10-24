import Foundation

/// Trimmed copies of real aviationweather.gov data (2026-10-24) for WeatherTests.
enum WeatherSamples {
    /// Like AWC's cache files: gzip with FNAME set.
    static let gzipWithFileName = "H4sICAAAAAAC/21ldGFycy5jYWNoZS5jc3YAK0osjy9JrSjRKS5JLMnMz4vPTOFS8nUNcQxScHUPDlYwMjE0MjWIUnAMDfFXMLQwMDT2DlGwBAIF3SBHBSdvP6CIgqGhvoGlQqChgYGJkg5IGxcA28LmMlcAAAA="
    static let gzipWithFileNameText = "raw_text,station_id\n\"METAR EGSS 241250Z AUTO 18013KT 9999 -RA BKN013 11/09 Q1004\",EGSS\n"
    /// FEXTRA (with a zero byte in it), FNAME, FCOMMENT and FHCRC; inflates to "SimPilot".
    static let gzipAllHeaderFields = "H4sIHgAAAAAAAwQAYWIAY25hbWUudHh0AGEgY29tbWVudAAu5AvOzA3IzMkvAQC1uTKeCAAAAA=="
    /// 200 000 bytes of "METAR METAR …".
    static let gzipLarge = "H4sIAAAAAAAC/+3EIQ0AAAgAsCpUQSAxjP5ZyID/xbs2J9q2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bdu2bT8+ELj5A0ANAwA="

    static let metarHeader = "raw_text,station_id,observation_time,latitude,longitude,temp_c,dewpoint_c,wind_dir_degrees,wind_speed_kt,wind_gust_kt,visibility_statute_mi,altim_in_hg,sea_level_pressure_mb,corrected,auto,auto_station,maintenance_indicator_on,no_signal,lightning_sensor_off,freezing_rain_sensor_off,present_weather_sensor_off,wx_string,sky_cover,cloud_base_ft_agl,sky_cover,cloud_base_ft_agl,sky_cover,cloud_base_ft_agl,sky_cover,cloud_base_ft_agl,flight_category,three_hr_pressure_tendency_mb,maxT_c,minT_c,maxT24hr_c,minT24hr_c,precip_in,pcp3hr_in,pcp6hr_in,pcp24hr_in,snow_in,vert_vis_ft,metar_type,elevation_m"

    /// Rows from metars.cache.csv (2026-10-24), plus a row without coordinates and a truncated row.
    static let metarRows = [
        "\"METAR MRPV 241400Z 09013G23KT 9999 FEW030 23/14 A3005 NOSIG\",MRPV,2026-10-24T12:56:39.000Z,9.9570,-84.1410,23,14,90,13,23,6+,30.05,,,,,,TRUE,,,,,FEW,3000,,,,,,,VFR,,,,,,,,,,,,METAR,998",
        "\"METAR KCVO 241256Z 00000KT 1 1/2SM BR FEW002 A3027 RMK AO2 SLPNO FZRANO $\",KCVO,2026-10-24T12:56:00.000Z,44.5013,-123.2930,,,0,0,,1.5,30.27,,,,TRUE,TRUE,,,TRUE,,BR,FEW,200,,,,,,,IFR,,,,,,,,,,,,METAR,75",
        "\"METAR ENWV 241250Z AUTO 24025KT 9999NDV FEW012/// BKN019/// 10/09 Q0996 W///S4\",ENWV,2026-10-24T12:50:00.000Z,56.2780,3.3950,10,9,240,25,,,29.41,,,TRUE,,,,,,,,FEW,1200,BKN,1900,,,,,null,,,,,,,,,,,,METAR,30",
        "\"METAR MWCB 241200Z 09005KT 9999 VCSH FEW016CB SCT020 25/23 Q1012 RMK VCSH-SE,S\",MWCB,2026-10-24T12:00:00.000Z,19.6880,-79.8790,25,23,90,5,,6+,29.88,,,,,,,,,,VCSH,FEW,1600,SCT,2000,,,,,VFR,,,,,,,,,,,,METAR,7",
        "\"METAR KIKW 241255Z AUTO 08003KT M1/4SM FG VV000 04/03 A3047 RMK AO2\",KIKW,2026-10-24T12:55:00.000Z,43.6643,-84.2613,4,3,80,3,,0.25,30.47,,,TRUE,TRUE,,,,,,FG,OVX,0,,,,,,,LIFR,,,,,,,,,,,0,METAR,190",
        "\"METAR KJKA 241256Z VRB03KT 10SM CLR 13/09 A3027\",KJKA,2026-10-24T12:56:00.000Z,30.2910,-87.6610,13,9,0,3,,10+,30.27,,,,,,,,,,,,,,,,,,,VFR,,,,,,,,,,,,METAR,5",
        "\"METAR KANJ 241255Z AUTO 11003KT 1SM BR VV002 09/08 A3043 RMK AO2 SLP309 T00890083 $\",KANJ,2026-10-24T12:55:00.000Z,46.4800,-84.3581,8.9,8.3,110,3,,1,30.43,1030.9,,TRUE,TRUE,TRUE,,,,,BR,OVX,200,,,,,,,LIFR,,,,,,,,,,,2,METAR,220",
        "\"METAR XXXX 241256Z VRB03KT 10SM CLR 13/09 A3027\",XXXX,2026-10-24T12:56:00.000Z,,,13,9,0,3,,10+,30.27,,,,,,,,,,,,,,,,,,,VFR,,,,,,,,,,,,METAR,5",
        "\"METAR YYYY 241256Z VRB03KT 10SM\",YYYY,2026-10-24T12:56:00.000Z,30.2910,-87.6610",
    ]

    static let egssRawTaf = "TAF EGSS 241054Z 2412/2518 20012KT 9999 SCT030 BECMG 2412/2415 20020G32KT TEMPO 2412/2423 6000 RA BKN010 PROB40 TEMPO 2412/2421 2500 +RA BKN007 PROB30 TEMPO 2415/2421 20024G42KT BECMG 2420/2423 26019G32KT TEMPO 2509/2515 27024G42KT BECMG 2515/2518 25014KT PROB40 TEMPO 2515/2518 24015G26KT"

    /// EGSS TAF from /api/data/taf?format=json (2026-10-24, nulls kept).
    static let egssTafJSON = """
    {"icaoId":"EGSS","issueTime":"2026-10-24T10:54:00.000Z","validTimeFrom":1792843200,"validTimeTo":1792951200,
     "rawTAF":"\(egssRawTaf)",
     "lat":51.881,"lon":0.223,"elev":101,"name":"London/Stansted Arpt","fcsts":[
      {"timeFrom":1792843200,"timeTo":1792951200,"timeBec":null,"fcstChange":null,"probability":null,"wdir":200,"wspd":12,"wgst":null,"visib":"6+","vertVis":null,"wxString":null,"clouds":[{"cover":"SCT","base":3000,"type":null}]},
      {"timeFrom":1792843200,"timeTo":1792872000,"timeBec":1792854000,"fcstChange":"BECMG","probability":null,"wdir":200,"wspd":20,"wgst":32,"visib":"6+","vertVis":null,"wxString":null,"clouds":[{"cover":"SCT","base":3000,"type":null}]},
      {"timeFrom":1792843200,"timeTo":1792882800,"timeBec":null,"fcstChange":"TEMPO","probability":null,"wdir":null,"wspd":null,"wgst":null,"visib":3.73,"vertVis":null,"wxString":"RA","clouds":[{"cover":"BKN","base":1000,"type":null}]},
      {"timeFrom":1792843200,"timeTo":1792875600,"timeBec":null,"fcstChange":"TEMPO","probability":40,"wdir":null,"wspd":null,"wgst":null,"visib":1.55,"vertVis":null,"wxString":"+RA","clouds":[{"cover":"BKN","base":700,"type":null}]},
      {"timeFrom":1792854000,"timeTo":1792875600,"timeBec":null,"fcstChange":"TEMPO","probability":30,"wdir":200,"wspd":24,"wgst":42,"visib":"","vertVis":null,"wxString":null,"clouds":[]},
      {"timeFrom":1792872000,"timeTo":1792940400,"timeBec":1792882800,"fcstChange":"BECMG","probability":null,"wdir":260,"wspd":19,"wgst":32,"visib":"6+","vertVis":null,"wxString":null,"clouds":[{"cover":"SCT","base":3000,"type":null}]},
      {"timeFrom":1792918800,"timeTo":1792940400,"timeBec":null,"fcstChange":"TEMPO","probability":null,"wdir":270,"wspd":24,"wgst":42,"visib":"","vertVis":null,"wxString":null,"clouds":[]},
      {"timeFrom":1792940400,"timeTo":1792951200,"timeBec":1792951200,"fcstChange":"BECMG","probability":null,"wdir":250,"wspd":14,"wgst":null,"visib":"6+","vertVis":null,"wxString":null,"clouds":[{"cover":"SCT","base":3000,"type":null}]},
      {"timeFrom":1792940400,"timeTo":1792951200,"timeBec":null,"fcstChange":"TEMPO","probability":40,"wdir":240,"wspd":15,"wgst":26,"visib":"","vertVis":null,"wxString":null,"clouds":[]}
     ]}
    """

    /// Two TAFs in the layout of tafs.cache.xml: groups in reverse order, raw text in CDATA.
    static let tafXML = """
    <?xml version="1.0" encoding="UTF-8"?><response version="2.0"><errors/><warnings/><time_taken_ms>0</time_taken_ms><data num_results="2">\
    <TAF><raw_text><![CDATA[TAF KRAP 241257Z 2413/2512 34022G35KT P6SM BKN130 BKN200 FM241500 34015G25KT P6SM FEW200 FM242000 01010KT P6SM SKC FM250000 VRB06KT P6SM BKN150]]></raw_text><station_id>KRAP</station_id><issue_time>2026-10-24T12:57:00.000Z</issue_time><valid_time_from>2026-10-24T13:00:00.000Z</valid_time_from><valid_time_to>2026-10-25T12:00:00.000Z</valid_time_to><remarks>AMD</remarks><latitude>44.0458</latitude><longitude>-103.0544</longitude><elevation_m>965.0000</elevation_m>\
    <forecast><fcst_time_from>2026-10-25T00:00:00.000Z</fcst_time_from><fcst_time_to>2026-10-25T12:00:00.000Z</fcst_time_to><change_indicator>FM</change_indicator><wind_dir_degrees>VRB</wind_dir_degrees><wind_speed_kt>6</wind_speed_kt><visibility_statute_mi>6+</visibility_statute_mi><sky_condition sky_cover="BKN" cloud_base_ft_agl="15000"/></forecast>\
    <forecast><fcst_time_from>2026-10-24T20:00:00.000Z</fcst_time_from><fcst_time_to>2026-10-25T00:00:00.000Z</fcst_time_to><change_indicator>FM</change_indicator><wind_dir_degrees>10</wind_dir_degrees><wind_speed_kt>10</wind_speed_kt><visibility_statute_mi>6+</visibility_statute_mi><sky_condition sky_cover="SKC"/></forecast>\
    <forecast><fcst_time_from>2026-10-24T15:00:00.000Z</fcst_time_from><fcst_time_to>2026-10-24T20:00:00.000Z</fcst_time_to><change_indicator>FM</change_indicator><wind_dir_degrees>340</wind_dir_degrees><wind_speed_kt>15</wind_speed_kt><wind_gust_kt>25</wind_gust_kt><visibility_statute_mi>6+</visibility_statute_mi><sky_condition sky_cover="FEW" cloud_base_ft_agl="20000"/></forecast>\
    <forecast><fcst_time_from>2026-10-24T13:00:00.000Z</fcst_time_from><fcst_time_to>2026-10-24T15:00:00.000Z</fcst_time_to><wind_dir_degrees>340</wind_dir_degrees><wind_speed_kt>22</wind_speed_kt><wind_gust_kt>35</wind_gust_kt><visibility_statute_mi>6+</visibility_statute_mi><sky_condition sky_cover="BKN" cloud_base_ft_agl="13000"/><sky_condition sky_cover="BKN" cloud_base_ft_agl="20000"/></forecast></TAF>\
    <TAF><raw_text><![CDATA[TAF EGXX 241100Z 2412/2512 20012KT 9999 SCT030 BECMG 2414/2416 BKN004 TEMPO 2412/2418 3000 RA PROB30 2418/2424 0800 FG VV001]]></raw_text><station_id>EGXX</station_id><issue_time>2026-10-24T11:00:00.000Z</issue_time><valid_time_from>2026-10-24T12:00:00.000Z</valid_time_from><valid_time_to>2026-10-25T12:00:00.000Z</valid_time_to><latitude>51.5</latitude><longitude>-1.0</longitude>\
    <forecast><fcst_time_from>2026-10-24T18:00:00.000Z</fcst_time_from><fcst_time_to>2026-10-25T00:00:00.000Z</fcst_time_to><change_indicator>PROB</change_indicator><probability>30</probability><visibility_statute_mi>0.50</visibility_statute_mi><wx_string>FG</wx_string><vert_vis_ft>100</vert_vis_ft></forecast>\
    <forecast><fcst_time_from>2026-10-24T12:00:00.000Z</fcst_time_from><fcst_time_to>2026-10-24T18:00:00.000Z</fcst_time_to><change_indicator>TEMPO</change_indicator><visibility_statute_mi>1.86</visibility_statute_mi><wx_string>RA</wx_string></forecast>\
    <forecast><fcst_time_from>2026-10-24T14:00:00.000Z</fcst_time_from><fcst_time_to>2026-10-25T12:00:00.000Z</fcst_time_to><change_indicator>BECMG</change_indicator><time_becoming>2026-10-24T16:00:00.000Z</time_becoming><wind_dir_degrees>200</wind_dir_degrees><wind_speed_kt>12</wind_speed_kt><visibility_statute_mi>6+</visibility_statute_mi><sky_condition sky_cover="BKN" cloud_base_ft_agl="400"/></forecast>\
    <forecast><fcst_time_from>2026-10-24T12:00:00.000Z</fcst_time_from><fcst_time_to>2026-10-25T12:00:00.000Z</fcst_time_to><wind_dir_degrees>200</wind_dir_degrees><wind_speed_kt>12</wind_speed_kt><visibility_statute_mi>6+</visibility_statute_mi><sky_condition sky_cover="SCT" cloud_base_ft_agl="3000"/></forecast></TAF>\
    </data></response>
    """

    /// /api/data/isigmet?format=json: a single area across the antimeridian, a two-area SIGMET, and an invalid one.
    static let sigmetJSON = """
    [{"firId":"KZAK","firName":"OAKLAND OCEANIC","validTimeFrom":1792826400,"validTimeTo":1792848000,"seriesId":"TANGO 3","hazard":"TC","qualifier":"INFA","base":null,"top":52000,"geom":"AREA",
      "coords":[{"lon":179.5,"lat":13.8},{"lon":-179.5,"lat":13.8},{"lon":-179.5,"lat":14.8},{"lon":179.5,"lat":14.8}],"dir":"NNW","spd":"4","chng":"INTSF","rawSigmet":"KZAK SIGMET TANGO 3 VALID 240720/241320 PHFO- MOV NNW 04KT. INTSF."},
     {"firId":"EDWW","firName":"BREMEN","validTimeFrom":1792840000,"validTimeTo":1792850000,"seriesId":"A1","hazard":"TURB","qualifier":"SEV","base":15000,"top":38000,"geom":"AREAS",
      "coords":[[{"lon":8,"lat":53},{"lon":9,"lat":53},{"lon":9,"lat":54}],[{"lon":10,"lat":53},{"lon":11,"lat":53},{"lon":11,"lat":54},{"lon":10,"lat":53}]],"dir":"-","spd":"0","chng":"NC","rawSigmet":"EDWW SIGMET A1 VALID 241200/241500 EDZH- SEV TURB FL150/380 STNR NC="},
     {"firId":"XXXX","validTimeFrom":1792840000,"validTimeTo":1792850000,"hazard":"TS","coords":[{"lon":1,"lat":1},{"lon":2,"lat":2}]}]
    """
}
