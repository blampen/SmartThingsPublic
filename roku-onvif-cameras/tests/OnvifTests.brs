' Off-device tests for the ONVIF, snapshot and bridge code in source/.
' Run with tests/run-tests.sh, which starts tests/fake_onvif_camera.py (and
' MediaMTX when available) and passes their addresses in as launch args:
'   camera=HOST:PORT  skew=SECONDS  bridge=HOST (optional)

sub Main(args as Dynamic)
    m.passed = 0
    m.failed = 0

    TestUtil()
    TestDigest()
    TestDiscoveryParsing()
    TestProfileSort()
    TestPresets()
    TestWallHelpers()

    camera = StrOrEmpty(args.camera)
    if camera <> "" then
        TestProbeAgainstFakeCamera(camera, AsInt(args.skew), StrOrEmpty(args.rtsp))
        TestSnapshots(camera)
        TestSnapshotConcurrency(camera)
    end if
    camera2 = StrOrEmpty(args.camera2)
    if camera2 <> "" then
        TestVendorSnapshotFallback(camera2)
    end if
    bridge = StrOrEmpty(args.bridge)
    if bridge <> "" then TestBridge(camera, bridge)

    print "TESTS: " + m.passed.ToStr() + " passed, " + m.failed.ToStr() + " failed"
end sub

' ---------------------------------------------------------------- units

sub TestUtil()
    Check("local name strips prefix", XmlLocalName("tt:Uri"), "Uri")
    Check("local name without prefix", XmlLocalName("Uri"), "Uri")

    parts = UrlParse("rtsp://u:p@10.0.0.5:554/Streaming/Channels/101?transportmode=unicast")
    Check("url host", parts.host, "10.0.0.5")
    Check("url port", parts.port, "554")
    Check("url rest", parts.rest, "/Streaming/Channels/101?transportmode=unicast")
    Check("url not absolute", UrlParse("10.0.0.5"), invalid)

    Check("credentials escaped", UrlWithCredentials("rtsp://10.0.0.5/live", "ad@min", "p:ss/w#rd"), "rtsp://ad%40min:p%3Ass%2Fw%23rd@10.0.0.5/live")
    Check("credentials replaced", UrlWithCredentials("rtsp://old:x@10.0.0.5:8554/live", "admin", "pw"), "rtsp://admin:pw@10.0.0.5:8554/live")
    Check("rehost stale ip", UrlRehost("http://192.168.1.64:80/onvif/Media", "192.168.1.30"), "http://192.168.1.30:80/onvif/Media")
    Check("rehost keeps hostnames", UrlRehost("http://cam.lan/onvif/Media", "192.168.1.30"), "http://cam.lan/onvif/Media")
    Check("device url from ip", DeviceServiceUrlFor(" 192.168.1.30:8000 "), "http://192.168.1.30:8000/onvif/device_service")
    Check("device url passthrough", DeviceServiceUrlFor("http://192.168.1.30/onvif/device_service"), "http://192.168.1.30/onvif/device_service")
    Check("safe key", SafeKey("urn:uuid:ab-12/x"), "urn_uuid_ab-12_x")
    Check("xml escape", XmlEscape("a<b>&""'"), "a&lt;b&gt;&amp;&quot;&apos;")
    Check("AsBool invalid", AsBool(invalid), false)
    Check("AsInt string", AsInt("42"), 42)

    xml = XmlParse("<a:Root xmlns:a=""x""><a:P token=""T1""><a:Name>main</a:Name><a:Enc><a:Name>inner</a:Name></a:Enc></a:P></a:Root>")
    p = XmlFind(xml, "P")
    Check("attr by local name", XmlAttr(p, "token"), "T1")
    Check("direct child name", XmlPathText(p, ["Name"]), "main")
    Check("nested path", XmlPathText(p, ["Enc", "Name"]), "inner")
    Check("find all", XmlFindAll(xml, "Name").Count(), 2)
end sub

sub TestDigest()
    nonce = CreateObject("roByteArray")
    for i = 0 to 15
        nonce.Push(i)
    end for
    Check("nonce base64", nonce.ToBase64String(), "AAECAwQFBgcICQoLDA0ODw==")
    ' Reference values computed with Python hashlib.
    Check("password digest", OnvifPasswordDigest(nonce, "2026-10-24T17:00:00Z", "s3cr&t!"), "Ik7H2Yn3zWO5ml4CAEN2uNasLBk=")

    nonce2 = CreateObject("roByteArray")
    nonce2.FromBase64String("/wCAB8gNY/oBAgMEBQYHCA==")
    Check("password digest utf-8", OnvifPasswordDigest(nonce2, "2026-10-24T17:00:00Z", "pässwörd"), "uu4sKOxjKa0jplZhJokeEGfbZU8=")

    header = OnvifSecurityHeader("ad<min", "x", 0, nonce, "2026-10-24T17:00:00Z")
    Check("username escaped in token", header.InStr("<wsse:Username>ad&lt;min</wsse:Username>") >= 0, true)
    Check("created in token", header.InStr("<wsu:Created>2026-10-24T17:00:00Z</wsu:Created>") >= 0, true)

    stamp = OnvifTimestamp(0)
    re = CreateObject("roRegex", "^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", "")
    Check("timestamp format", re.IsMatch(stamp), true)

    Check("anonymous envelope has no header", OnvifEnvelope("<x/>", invalid).InStr("Header") < 0, true)
    probe = XmlParse(OnvifProbeMessage("dn:NetworkVideoTransmitter", "1234"))
    Check("probe parses", probe <> invalid, true)
    Check("probe types", XmlText(XmlFind(probe, "Types")), "dn:NetworkVideoTransmitter")
end sub

sub TestDiscoveryParsing()
    ' Hikvision style: IPv4 + link-local IPv6 XAddrs, escaped name scope.
    hik = "<?xml version=""1.0"" encoding=""UTF-8""?><env:Envelope xmlns:env=""http://www.w3.org/2003/05/soap-envelope"" xmlns:wsadis=""http://schemas.xmlsoap.org/ws/2004/08/addressing"" xmlns:wsdd=""http://schemas.xmlsoap.org/ws/2005/04/discovery"" xmlns:dn=""http://www.onvif.org/ver10/network/wsdl"" xmlns:tds=""http://www.onvif.org/ver10/device/wsdl"">"
    hik = hik + "<env:Header><wsadis:MessageID>urn:uuid:11112222-3333-4444-5555-c056e3a1b2c3</wsadis:MessageID><wsadis:RelatesTo>uuid:1234</wsadis:RelatesTo><wsadis:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</wsadis:Action></env:Header>"
    hik = hik + "<env:Body><wsdd:ProbeMatches><wsdd:ProbeMatch><wsadis:EndpointReference><wsadis:Address>urn:uuid:a1b2c3d4-0000-1111-2222-c056e3a1b2c3</wsadis:Address></wsadis:EndpointReference>"
    hik = hik + "<wsdd:Types>dn:NetworkVideoTransmitter tds:Device</wsdd:Types>"
    hik = hik + "<wsdd:Scopes>onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/Profile/Streaming onvif://www.onvif.org/MAC/c0:56:e3:a1:b2:c3 onvif://www.onvif.org/hardware/DS-2CD2143G0-I onvif://www.onvif.org/name/HIKVISION%20DS-2CD2143G0-I onvif://www.onvif.org/location/city/hangzhou</wsdd:Scopes>"
    hik = hik + "<wsdd:XAddrs>http://[fe80::c256:e3ff:fea1:b2c3]/onvif/device_service http://192.168.1.64/onvif/device_service</wsdd:XAddrs><wsdd:MetadataVersion>10</wsdd:MetadataVersion></wsdd:ProbeMatch></wsdd:ProbeMatches></env:Body></env:Envelope>"
    found = OnvifParseProbeMatches(hik, "")
    Check("hik match count", found.Count(), 1)
    if found.Count() = 1 then
        Check("hik id", found[0].id, "urn:uuid:a1b2c3d4-0000-1111-2222-c056e3a1b2c3")
        Check("hik prefers ipv4 xaddr", found[0].xaddr, "http://192.168.1.64/onvif/device_service")
        Check("hik host", found[0].host, "192.168.1.64")
        Check("hik name", found[0].name, "HIKVISION DS-2CD2143G0-I")
        Check("hik hardware", found[0].hardware, "DS-2CD2143G0-I")
    end if

    ' Dahua style: different prefixes, two XAddrs on two subnets, two matches.
    dahua = "<SOAP-ENV:Envelope xmlns:SOAP-ENV=""http://www.w3.org/2003/05/soap-envelope"" xmlns:wsa5=""http://www.w3.org/2005/08/addressing"" xmlns:d=""http://schemas.xmlsoap.org/ws/2005/04/discovery""><SOAP-ENV:Body><d:ProbeMatches>"
    dahua = dahua + "<d:ProbeMatch><wsa5:EndpointReference><wsa5:Address>uuid:dahua-0001</wsa5:Address></wsa5:EndpointReference><d:Scopes>onvif://www.onvif.org/name/Dahua_Garage onvif://www.onvif.org/hardware/IPC-HDW2431T</d:Scopes><d:XAddrs>http://10.10.0.20/onvif/device_service http://192.168.1.108/onvif/device_service</d:XAddrs></d:ProbeMatch>"
    dahua = dahua + "<d:ProbeMatch><wsa5:EndpointReference><wsa5:Address>uuid:dahua-0002</wsa5:Address></wsa5:EndpointReference><d:XAddrs>http://192.168.1.109:8080/onvif/device_service</d:XAddrs></d:ProbeMatch>"
    dahua = dahua + "</d:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>"
    found = OnvifParseProbeMatches(dahua, "192.168.1.108")
    Check("dahua match count", found.Count(), 2)
    if found.Count() = 2 then
        Check("dahua xaddr follows sender", found[0].xaddr, "http://192.168.1.108/onvif/device_service")
        Check("dahua name underscores", found[0].name, "Dahua Garage")
        Check("dahua second id", found[1].id, "uuid:dahua-0002")
        Check("dahua second has no name", found[1].name, "")
    end if

    Check("garbage ignored", OnvifParseProbeMatches("not xml", "").Count(), 0)
end sub

sub TestProfileSort()
    sorted = OnvifSortProfiles([
        { token: "jpeg", encoding: "JPEG", width: 1920, height: 1080 }
        { token: "sub", encoding: "H264", width: 640, height: 360 }
        { token: "main", encoding: "H264", width: 2560, height: 1440 }
        { token: "third", encoding: "H265", width: 1280, height: 720 }
    ])
    order = []
    for each p in sorted
        order.Push(p.token)
    end for
    Check("profile order", order.Join(","), "main,third,sub,jpeg")
end sub

sub TestWallHelpers()
    tracks = [{ Name: "audio3", Track: "t3" }, { Name: "audio2", Track: "t2" }, { Name: "audio5", Track: "t5" }, { Name: "audio4", Track: "t4" }]
    Check("camera 1 sound", WallAudioTrack(tracks, 0), "t2")
    Check("camera 4 sound", WallAudioTrack(tracks, 3), "t5")
    Check("no such camera", WallAudioTrack(tracks, 4), "")
    Check("unnamed tracks in list order", WallAudioTrack([{ Track: "a" }, { Track: "b" }], 1), "b")
    Check("MinInt", MinInt(7, 4), 4)

    profiles = [
        { width: 2560, streamUri: "rtsp://10.0.0.5/main", snapshotUri: "" }
        { width: 1280, streamUri: "rtsp://10.0.0.5/third", snapshotUri: "" }
        { width: 640, streamUri: "rtsp://10.0.0.5/sub", snapshotUri: "" }
    ]
    cam = { status: "online", profiles: profiles, profile: 0, ownLogin: true, user: "admin", pass: "p!" }
    paths = CameraBridgePaths(cam, 3, DefaultSettings())
    Check("main path", paths[0].name, "cam3_main")
    Check("main url has login", paths[0].url, "rtsp://admin:p%21@10.0.0.5/main")
    Check("wall uses sub stream", paths[1].url, "rtsp://admin:p%21@10.0.0.5/sub")
    cam.status = "offline"
    Check("offline camera removed", CameraBridgePaths(cam, 3, DefaultSettings())[0].url, "")
    Check("hevc detected", IsHevc({ encoding: "H265" }), true)
    Check("h264 not hevc", IsHevc({ encoding: "H264" }), false)
end sub

sub TestPresets()
    text = "{""user"":""admin"",""pass"":""p@ss!"",""settings"":{""refreshSec"":1},""cameras"":["
    text = text + "{""name"":""One"",""address"":""192.168.0.20""},"
    text = text + "{""address"":""192.168.0.21:8000"",""user"":""viewer"",""pass"":""x""},"
    text = text + "{""address"":""http://192.168.0.22/onvif/device_service""},"
    text = text + "{""name"":""no address""}]}"
    presets = ParsePresets(text)
    Check("presets parsed", presets <> invalid, true)
    if presets = invalid then return
    cams = presets.cameras
    Check("presets skip entries without address", cams.Count(), 3)
    Check("preset id", cams[0].id, "preset:192.168.0.20")
    Check("preset name", CameraTitle(cams[0]), "One")
    Check("preset xaddr", cams[0].xaddr, "http://192.168.0.20/onvif/device_service")
    Check("preset shared login", CameraLogin(cams[0], DefaultSettings()).pass, "p@ss!")
    Check("bare ip scans ports", cams[0].autoPort, true)
    Check("explicit port kept", cams[1].autoPort, false)
    Check("explicit url kept", cams[2].autoPort, false)
    Check("per-camera login", CameraLogin(cams[1], DefaultSettings()).user, "viewer")
    Check("preset settings", presets.settings.refreshSec, 1)

    saved = [{ id: "preset:192.168.0.20", xaddr: "http://192.168.0.20:2020/onvif/device_service", profile: 1 }]
    merged = ApplySavedCameraState(cams, saved)
    Check("remembered port", merged[0].xaddr, "http://192.168.0.20:2020/onvif/device_service")
    Check("remembered stream", merged[0].profile, 1)
    Check("others untouched", merged[1].xaddr, "http://192.168.0.21:8000/onvif/device_service")

    Check("no presets file", ParsePresets(""), invalid)
    Check("presets without cameras", ParsePresets("{""cameras"":[]}"), invalid)
    Check("presets garbage", ParsePresets("nope"), invalid)
end sub

' ---------------------------------------------------------------- fake camera

sub TestProbeAgainstFakeCamera(address as String, skew as Integer, rtspPort as String)
    deviceUrl = DeviceServiceUrlFor(address)
    host = UrlHost(deviceUrl)

    clock = OnvifGetClockOffset(deviceUrl)
    Check("clock reachable", clock.reachable, true)
    if clock.offset <> invalid then
        Check("clock offset ~ skew", Abs(clock.offset - skew) <= 2, true)
    else
        Check("clock offset read", false, true)
    end if

    if skew <> 0 then
        ' Without the clock correction the camera rejects the token.
        noSkew = OnvifGetProfiles(deviceUrl.Replace("device_service", "media_service"), { user: "admin", pass: "secret", timeOffset: 0 })
        Check("unskewed token rejected", noSkew.authFailed, true)
    end if

    result = OnvifProbeCamera({ xaddr: deviceUrl, user: "admin", pass: "secret" })
    Check("probe ok", result.ok, true)
    if not result.ok then
        print "  probe error: " + result.error
        return
    end if
    info = result.info
    Check("manufacturer", info.manufacturer, "FakeCam")
    Check("media url rehosted", info.mediaUrl, "http://" + host + ":" + UrlParse(deviceUrl).port + "/onvif/media_service")
    Check("video profiles only", info.profiles.Count(), 3)
    if info.profiles.Count() = 3 then
        main = info.profiles[0]
        Check("main first", main.token, "Profile_1")
        Check("main size", ProfileLabel(main), "1280x720 H264 15fps (mainStream)")
        Check("jpeg last", info.profiles[2].encoding, "JPEG")
        Check("stream uri rehosted + unescaped", main.streamUri, "rtsp://" + host + ":" + rtspPort + "/fakecam?profile=Profile_1&x=1")
        Check("snapshot uri", main.snapshotUri, "http://" + host + ":" + UrlParse(deviceUrl).port + "/snapshot.jpg?profile=Profile_1")
        cam = { profiles: info.profiles, profile: 7 }
        Check("thumbnail uses smallest", CameraThumbnailUri(cam), info.profiles[1].snapshotUri)
        Check("wall thumbnail big enough", CameraThumbnailUri(cam, 924), main.snapshotUri)
        Check("thumbnail falls back to largest", CameraThumbnailUri(cam, 5000), info.profiles[2].snapshotUri)
        Check("profile index clamped", CameraProfile(cam).token, "Profile_1")
    end if

    bad = OnvifProbeCamera({ xaddr: deviceUrl, user: "admin", pass: "wrong" })
    Check("wrong password fails", bad.ok, false)
    Check("wrong password is auth failure", bad.authFailed, true)

    port = UrlParse(deviceUrl).port
    Check("port scan finds onvif", OnvifFindDeviceUrl(host, [9, port.ToInt()], ""), deviceUrl)
    Check("port scan skips tried url", OnvifFindDeviceUrl(host, [port.ToInt()], deviceUrl), "")
    Check("port scan none", OnvifFindDeviceUrl(host, [9], ""), "")

    gone = OnvifProbeCamera({ xaddr: "http://127.0.0.1:9/onvif/device_service", user: "admin", pass: "secret" })
    Check("unreachable camera fails", gone.ok, false)
    Check("unreachable message names host", gone.error.InStr("127.0.0.1") >= 0, true)
end sub

sub TestVendorSnapshotFallback(address as String)
    deviceUrl = DeviceServiceUrlFor(address)
    result = OnvifProbeCamera({ xaddr: deviceUrl, user: "admin", pass: "secret" })
    Check("camera without onvif snapshots probes", result.ok, true)
    if not result.ok then return
    expected = "http://" + address + "/ISAPI/Streaming/channels/101/picture"
    Check("vendor snapshot found", CameraThumbnailUri({ profiles: result.info.profiles }), expected)
    frames = PollSnapshots([{ key: "vendor", url: expected, user: "admin", pass: "secret", intervalMs: 200 }], 1, 8000)
    vendor = frames["vendor"]
    Check("vendor snapshot fetched", vendor.Count() > 0 and vendor[0].ok and vendor[0].jpeg, true)
    ' A rejected login ends the search instead of trying every address.
    Check("search stops on wrong login", OnvifFindSnapshotUrl(deviceUrl, "admin", "wrong"), "")
end sub

sub TestSnapshotConcurrency(address as String)
    jobs = []
    for i = 1 to 8
        jobs.Push({ key: "cam" + i.ToStr(), url: "http://" + address + "/snapshot.jpg?profile=Profile_2", user: "admin", pass: "secret", intervalMs: 100 })
    end for
    frames = PollSnapshots(jobs, 2, 15000, 3)
    Check("in-flight requests capped", m.peakInFlight <= 3, true)
    served = 0
    for each key in frames
        if frames[key].Count() >= 2 then served = served + 1
    end for
    Check("every camera served under the cap", served, 8)
end sub

sub TestSnapshots(address as String)
    url = "http://" + address + "/snapshot.jpg?profile=Profile_2"
    frames = PollSnapshots([
        { key: "good", url: url, user: "admin", pass: "secret", intervalMs: 200 }
        { key: "bad", url: url, user: "admin", pass: "nope", intervalMs: 200 }
    ], 3, 8000)

    good = frames["good"]
    Check("snapshot frames received", good.Count() >= 2, true)
    if good.Count() > 0 then
        Check("snapshot ok", good[0].ok, true)
        Check("snapshot file distinct", good.Count() < 2 or good[0].uri <> good[1].uri, true)
        Check("snapshot is jpeg", good[0].jpeg, true)
    end if
    bad = frames["bad"]
    Check("bad login reported", bad.Count() >= 1, true)
    if bad.Count() > 0 then
        Check("bad login not ok", bad[0].ok, false)
        Check("bad login reason", bad[0].error, "Snapshot login rejected")
    end if
end sub

' Runs a poller until every job produced `count` frames or time runs out.
function PollSnapshots(jobs as Object, count as Integer, timeoutMs as Integer, maxInFlight = 6 as Integer) as Object
    port = CreateObject("roMessagePort")
    poller = NewSnapshotPoller(port)
    poller.maxInFlight = maxInFlight
    m.peakInFlight = 0
    poller.setJobs(jobs)
    frames = {}
    for each job in jobs
        frames[job.key] = []
    end for
    clock = CreateObject("roTimespan")
    clock.Mark()
    while clock.TotalMilliseconds() < timeoutMs
        for each frame in poller.tick()
            frames[frame.key].Push(frame)
        end for
        if poller.byTransfer.Count() > m.peakInFlight then m.peakInFlight = poller.byTransfer.Count()
        msg = wait(50, port)
        if type(msg) = "roUrlEvent" then
            frame = poller.handle(msg)
            if frame <> invalid then
                ' Check the file now: the poller deletes old frames.
                bytes = CreateObject("roByteArray")
                frame.jpeg = frame.ok and bytes.ReadFile(frame.uri) and bytes.Count() > 100 and bytes[0] = 255 and bytes[1] = 216
                frames[frame.key].Push(frame)
            end if
        end if
        done = true
        for each key in frames
            if frames[key].Count() < count then done = false
        end for
        if done then exit while
    end while
    poller.stopAll()
    return frames
end function

' ---------------------------------------------------------------- bridge

sub TestBridge(cameraAddress as String, bridgeHost as String)
    settings = DefaultSettings()
    settings.bridgeHost = bridgeHost

    info = BridgeInfo(settings)
    Check("bridge reachable", info.ok, true)
    print "  bridge version: " + info.version

    probe = OnvifProbeCamera({ xaddr: DeviceServiceUrlFor(cameraAddress), user: "admin", pass: "secret" })
    if not probe.ok then
        Check("bridge test probe", probe.error, "")
        return
    end if
    ' Camera 1 is the fake camera; 2-4 stay unregistered (shown black).
    cam = { status: "online", profiles: probe.info.profiles, profile: 0, ownLogin: true, user: "admin", pass: "secret" }
    paths = CameraBridgePaths(cam, 1, settings)
    paths.Append(CameraBridgePaths({ status: "offline" }, 2, settings))
    reg = BridgeRegisterAll(settings, paths)
    Check("bridge register", reg.ok, true)
    Check("bridge re-register", BridgeRegisterAll(settings, paths).ok, true)
    Check("hls url", BridgeFullUrl(settings, 1), "http://" + bridgeHost + ":8888/full1/index.m3u8")

    ' Full screen: video passed through (H.265 here), audio as AAC.
    ' The first request starts the bridge's ffmpeg; it can take a moment.
    full = HttpRequest({ url: BridgeFullUrl(settings, 1), timeoutMs: 30000 })
    Check("full screen playlist served", full.code, 200)
    Check("full screen keeps H.265", full.body.InStr("hvc1") >= 0, true)
    Check("full screen audio is AAC", full.body.InStr("mp4a") >= 0, true)

    ' The wall: one 1920x1080 picture, an audio track per camera.
    wall = HttpRequest({ url: BridgeWallUrl(settings), timeoutMs: 45000 })
    Check("wall playlist served", wall.code, 200)
    Check("wall is one 1080p picture", wall.body.InStr("RESOLUTION=1920x1080") >= 0, true)
    Check("wall has 4 audio tracks", CountOf(wall.body, "TYPE=AUDIO"), 4)

    badSettings = DefaultSettings()
    badSettings.bridgeHost = "127.0.0.1"
    badSettings.bridgeApiPort = 9
    unreachable = BridgeRegister(badSettings, "cam1_main", "rtsp://x/y")
    Check("unreachable bridge fails", unreachable.ok, false)
end sub

function CountOf(text as String, part as String) as Integer
    count = 0
    start = text.InStr(part)
    while start >= 0
        count = count + 1
        start = text.InStr(start + 1, part)
    end while
    return count
end function

' ---------------------------------------------------------------- harness

sub Check(name as String, actual as Dynamic, expected as Dynamic)
    a = TestText(actual)
    e = TestText(expected)
    if a = e then
        m.passed = m.passed + 1
    else
        m.failed = m.failed + 1
        print "FAIL " + name + ": expected " + e + ", got " + a
    end if
end sub

function TestText(value as Dynamic) as String
    if value = invalid then return "invalid"
    if GetInterface(value, "ifString") <> invalid then return Chr(34) + value + Chr(34)
    if GetInterface(value, "ifToStr") <> invalid then return value.ToStr()
    return FormatJson(value)
end function
