' ONVIF client: WS-Discovery messages, SOAP with WS-Security UsernameToken
' authentication, and the Device/Media (ver10) calls needed to find each
' camera's RTSP streams and JPEG snapshots. Uses blocking HTTP, so call it
' from Task threads only.

function OnvifNs() as Object
    return {
        soap: "http://www.w3.org/2003/05/soap-envelope"
        wsa: "http://schemas.xmlsoap.org/ws/2004/08/addressing"
        wsd: "http://schemas.xmlsoap.org/ws/2005/04/discovery"
        wsse: "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
        wsu: "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
        device: "http://www.onvif.org/ver10/device/wsdl"
        media: "http://www.onvif.org/ver10/media/wsdl"
        schema: "http://www.onvif.org/ver10/schema"
        network: "http://www.onvif.org/ver10/network/wsdl"
    }
end function

' ---------------------------------------------------------------- discovery

' A WS-Discovery Probe. types is "dn:NetworkVideoTransmitter" or
' "tds:Device"; cameras differ in which one they answer, so send both.
function OnvifProbeMessage(types as String, messageId as String) as String
    ns = OnvifNs()
    xml = "<?xml version=""1.0"" encoding=""UTF-8""?>"
    xml = xml + "<s:Envelope xmlns:s=""" + ns.soap + """ xmlns:a=""" + ns.wsa + """ xmlns:d=""" + ns.wsd + """"
    xml = xml + " xmlns:dn=""" + ns.network + """ xmlns:tds=""" + ns.device + """>"
    xml = xml + "<s:Header>"
    xml = xml + "<a:Action s:mustUnderstand=""1"">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action>"
    xml = xml + "<a:MessageID>uuid:" + messageId + "</a:MessageID>"
    xml = xml + "<a:ReplyTo><a:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address></a:ReplyTo>"
    xml = xml + "<a:To s:mustUnderstand=""1"">urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To>"
    xml = xml + "</s:Header>"
    xml = xml + "<s:Body><d:Probe><d:Types>" + types + "</d:Types></d:Probe></s:Body>"
    return xml + "</s:Envelope>"
end function

' Parses a ProbeMatches datagram into
' [{ id, xaddr, host, name, hardware, location }]. senderHost is the IP the
' datagram came from and is used to pick the right XAddr on multi-homed
' devices.
function OnvifParseProbeMatches(text as String, senderHost = "" as String) as Object
    results = []
    xml = XmlParse(text)
    if xml = invalid then return results

    for each match in XmlFindAll(xml, "ProbeMatch")
        xaddr = OnvifPickXAddr(XmlText(XmlFind(match, "XAddrs")), senderHost)
        if xaddr <> "" then
            id = XmlText(XmlFind(XmlFind(match, "EndpointReference"), "Address"))
            if id = "" then id = "host:" + UrlHost(xaddr)
            scopes = OnvifParseScopes(XmlText(XmlFind(match, "Scopes")))
            results.Push({
                id: id
                xaddr: xaddr
                host: UrlHost(xaddr)
                name: scopes.name
                hardware: scopes.hardware
                location: scopes.location
            })
        end if
    end for
    return results
end function

' XAddrs is a space separated list; prefer an http URL on the host that
' answered, then any IPv4 http URL, then whatever is first.
function OnvifPickXAddr(xaddrs as String, senderHost as String) as String
    candidates = []
    for each item in xaddrs.Split(" ")
        item = item.Trim()
        if UrlParse(item) <> invalid then candidates.Push(item)
    end for
    if candidates.Count() = 0 then return ""

    for each url in candidates
        if senderHost <> "" and UrlHost(url) = senderHost then return url
    end for
    for each url in candidates
        if Left(LCase(url), 5) = "http:" and Left(UrlHost(url), 1) <> "[" then return url
    end for
    return candidates[0]
end function

function OnvifParseScopes(scopes as String) as Object
    out = { name: "", hardware: "", location: "" }
    prefix = "onvif://www.onvif.org/"
    for each scope in scopes.Split(" ")
        scope = scope.Trim()
        if LCase(Left(scope, Len(prefix))) = prefix then
            rest = Mid(scope, Len(prefix) + 1)
            slash = Instr(1, rest, "/")
            if slash > 0 then
                key = LCase(Left(rest, slash - 1))
                value = UrlUnescape(Mid(rest, slash + 1)).Replace("_", " ").Trim()
                if out.DoesExist(key) and out[key] = "" then out[key] = value
            end if
        end if
    end for
    return out
end function

' ---------------------------------------------------------------- SOAP

' ctx: { user, pass, timeOffset } where timeOffset is camera clock minus
' ours, in seconds (WS-Security tokens are rejected when the clocks differ).
function OnvifEnvelope(body as String, ctx as Dynamic) as String
    ns = OnvifNs()
    header = ""
    if ctx <> invalid and StrOrEmpty(ctx.user) <> "" then
        header = "<s:Header>" + OnvifSecurityHeader(ctx.user, StrOrEmpty(ctx.pass), AsInt(ctx.timeOffset), invalid, "") + "</s:Header>"
    end if
    xml = "<?xml version=""1.0"" encoding=""UTF-8""?>"
    return xml + "<s:Envelope xmlns:s=""" + ns.soap + """>" + header + "<s:Body>" + body + "</s:Body></s:Envelope>"
end function

' WS-Security UsernameToken with PasswordDigest =
' Base64(SHA1(nonce + created + password)). nonce (roByteArray) and created
' can be passed in for testing; normally they are generated.
function OnvifSecurityHeader(user as String, pass as String, timeOffset as Integer, nonce as Dynamic, created as String) as String
    ns = OnvifNs()
    if nonce = invalid then
        nonce = CreateObject("roByteArray")
        for i = 1 to 16
            nonce.Push(Rnd(256) - 1)
        end for
    end if
    if created = "" then created = OnvifTimestamp(timeOffset)

    xml = "<wsse:Security s:mustUnderstand=""1"" xmlns:wsse=""" + ns.wsse + """ xmlns:wsu=""" + ns.wsu + """>"
    xml = xml + "<wsse:UsernameToken>"
    xml = xml + "<wsse:Username>" + XmlEscape(user) + "</wsse:Username>"
    xml = xml + "<wsse:Password Type=""http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest"">" + OnvifPasswordDigest(nonce, created, pass) + "</wsse:Password>"
    xml = xml + "<wsse:Nonce EncodingType=""http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary"">" + nonce.ToBase64String() + "</wsse:Nonce>"
    xml = xml + "<wsu:Created>" + created + "</wsu:Created>"
    xml = xml + "</wsse:UsernameToken>"
    return xml + "</wsse:Security>"
end function

function OnvifPasswordDigest(nonce as Object, created as String, pass as String) as String
    tail = CreateObject("roByteArray")
    tail.FromAsciiString(created + pass)
    input = CreateObject("roByteArray")
    for each b in nonce
        input.Push(b)
    end for
    for each b in tail
        input.Push(b)
    end for

    sha1 = CreateObject("roEVPDigest")
    sha1.Setup("sha1")
    digest = CreateObject("roByteArray")
    digest.FromHexString(sha1.Process(input))
    return digest.ToBase64String()
end function

' Current UTC time shifted by offsetSeconds, as xsd:dateTime.
function OnvifTimestamp(offsetSeconds as Integer) as String
    dt = CreateObject("roDateTime")
    dt.FromSeconds(dt.AsSeconds() + offsetSeconds)
    day = dt.GetYear().ToStr() + "-" + PadTwo(dt.GetMonth()) + "-" + PadTwo(dt.GetDayOfMonth())
    return day + "T" + PadTwo(dt.GetHours()) + ":" + PadTwo(dt.GetMinutes()) + ":" + PadTwo(dt.GetSeconds()) + "Z"
end function

' Calls operation op of service ns at url.
' Returns { ok, code, xml, response, fault, authFailed, error }.
function OnvifCall(url as String, ns as String, op as String, inner as String, ctx as Dynamic, timeoutMs = 8000 as Integer) as Object
    body = "<" + op + " xmlns=""" + ns + """>" + inner + "</" + op + ">"
    opts = {
        url: url
        method: "POST"
        body: OnvifEnvelope(body, ctx)
        headers: { "Content-Type": "application/soap+xml; charset=utf-8; action=""" + ns + "/" + op + """" }
        timeoutMs: timeoutMs
    }
    if ctx <> invalid then
        ' Some firmware protects the SOAP endpoint with HTTP Digest instead
        ' of (or as well as) WS-Security.
        opts.user = ctx.user
        opts.pass = ctx.pass
    end if
    res = HttpRequest(opts)

    result = { ok: false, code: res.code, xml: invalid, response: invalid, fault: "", authFailed: false, error: "" }
    result.xml = XmlParse(res.body)
    result.response = XmlFind(result.xml, op + "Response")
    fault = XmlFind(result.xml, "Fault")

    if HttpIsSuccess(res.code) and fault = invalid and result.response <> invalid then
        result.ok = true
        return result
    end if

    if fault <> invalid then
        reason = XmlText(XmlFind(XmlFind(fault, "Reason"), "Text"))
        subcode = ""
        for each value in XmlFindAll(fault, "Value")
            subcode = XmlText(value)
        end for
        result.fault = subcode
        if LCase(subcode).InStr("notauthorized") >= 0 or LCase(reason).InStr("authori") >= 0 or LCase(reason).InStr("password") >= 0 then
            result.authFailed = true
        end if
        result.error = reason
        if result.error = "" then result.error = subcode
    end if
    if res.code = 401 then result.authFailed = true

    if result.authFailed then
        result.error = "Login failed - check the camera's ONVIF username and password"
    else if result.error = "" then
        if res.code > 0 and HttpIsSuccess(res.code) then
            result.error = "Unexpected response to " + op
        else
            result.error = HttpErrorText(res)
        end if
    end if
    return result
end function

' ---------------------------------------------------------------- device

' Camera clock minus ours in seconds, or invalid if it could not be read.
' This call is unauthenticated by spec, so it works before we know the login.
function OnvifGetClockOffset(deviceUrl as String, timeoutMs = 8000 as Integer) as Object
    res = OnvifCall(deviceUrl, OnvifNs().device, "GetSystemDateAndTime", "", invalid, timeoutMs)
    ' Any SOAP reply (even a fault) or an auth challenge means an ONVIF
    ' service is listening there.
    out = { reachable: res.xml <> invalid or res.code = 401, code: res.code, error: HttpErrorText(res), offset: invalid }
    if not res.ok then return out

    utc = XmlFind(res.response, "UTCDateTime")
    if utc = invalid then return out
    date = XmlChild(utc, "Date")
    time = XmlChild(utc, "Time")
    if date = invalid or time = invalid then return out

    iso = XmlPathText(date, ["Year"]) + "-" + PadTwo(AsInt(XmlPathText(date, ["Month"]))) + "-" + PadTwo(AsInt(XmlPathText(date, ["Day"])))
    iso = iso + "T" + PadTwo(AsInt(XmlPathText(time, ["Hour"]))) + ":" + PadTwo(AsInt(XmlPathText(time, ["Minute"]))) + ":" + PadTwo(AsInt(XmlPathText(time, ["Second"]))) + "Z"
    camera = CreateObject("roDateTime")
    camera.FromISO8601String(iso)
    now = CreateObject("roDateTime")
    out.offset = camera.AsSeconds() - now.AsSeconds()
    return out
end function

function OnvifGetDeviceInformation(deviceUrl as String, ctx as Object) as Object
    res = OnvifCall(deviceUrl, OnvifNs().device, "GetDeviceInformation", "", ctx)
    if not res.ok then return res
    res.info = {
        manufacturer: XmlText(XmlFind(res.response, "Manufacturer"))
        model: XmlText(XmlFind(res.response, "Model"))
        firmware: XmlText(XmlFind(res.response, "FirmwareVersion"))
    }
    return res
end function

' Finds the Media service URL: GetCapabilities, then GetServices (some newer
' firmware only implements the latter).
function OnvifGetMediaUrl(deviceUrl as String, ctx as Object) as Object
    ns = OnvifNs()
    res = OnvifCall(deviceUrl, ns.device, "GetCapabilities", "<Category>All</Category>", ctx)
    if res.ok then
        for each media in XmlFindAll(res.response, "Media")
            url = XmlPathText(media, ["XAddr"])
            if url <> "" then
                res.url = url
                return res
            end if
        end for
    end if
    if res.authFailed then return res

    res = OnvifCall(deviceUrl, ns.device, "GetServices", "<IncludeCapability>false</IncludeCapability>", ctx)
    if res.ok then
        for each service in XmlFindAll(res.response, "Service")
            if XmlPathText(service, ["Namespace"]) = ns.media then
                res.url = XmlPathText(service, ["XAddr"])
                return res
            end if
        end for
        res.ok = false
        res.error = "Camera does not offer an ONVIF media service"
    end if
    return res
end function

' ---------------------------------------------------------------- media

' Video profiles sorted best first: H.264/H.265 before other encodings,
' then by resolution, largest first.
function OnvifGetProfiles(mediaUrl as String, ctx as Object) as Object
    res = OnvifCall(mediaUrl, OnvifNs().media, "GetProfiles", "", ctx)
    if not res.ok then return res

    profiles = []
    for each node in XmlFindAll(res.response, "Profiles")
        encoder = XmlChild(node, "VideoEncoderConfiguration")
        token = XmlAttr(node, "token")
        if encoder <> invalid and token <> "" then
            profiles.Push({
                token: token
                name: XmlPathText(node, ["Name"])
                encoding: UCase(XmlPathText(encoder, ["Encoding"]))
                width: AsInt(XmlPathText(encoder, ["Resolution", "Width"]))
                height: AsInt(XmlPathText(encoder, ["Resolution", "Height"]))
                fps: AsInt(XmlPathText(encoder, ["RateControl", "FrameRateLimit"]))
                streamUri: ""
                snapshotUri: ""
            })
        end if
    end for
    res.profiles = OnvifSortProfiles(profiles)
    if res.profiles.Count() = 0 then
        res.ok = false
        res.error = "Camera has no video profiles"
    end if
    return res
end function

function OnvifSortProfiles(profiles as Object) as Object
    for each p in profiles
        rank = p.width * p.height
        if p.encoding = "H264" or p.encoding = "H265" or p.encoding = "HEVC" then rank = rank + 100000000
        p.rank = rank
    end for
    ' Insertion sort keeps the camera's order for equal ranks.
    sorted = []
    for each p in profiles
        i = sorted.Count()
        while i > 0 and sorted[i - 1].rank < p.rank
            i = i - 1
        end while
        sorted.Push(invalid)
        j = sorted.Count() - 1
        while j > i
            sorted[j] = sorted[j - 1]
            j = j - 1
        end while
        sorted[i] = p
    end for
    for each p in sorted
        p.Delete("rank")
    end for
    return sorted
end function

function OnvifGetStreamUri(mediaUrl as String, token as String, ctx as Object) as Object
    ns = OnvifNs()
    inner = "<StreamSetup>"
    inner = inner + "<Stream xmlns=""" + ns.schema + """>RTP-Unicast</Stream>"
    inner = inner + "<Transport xmlns=""" + ns.schema + """><Protocol>RTSP</Protocol></Transport>"
    inner = inner + "</StreamSetup>"
    inner = inner + "<ProfileToken>" + XmlEscape(token) + "</ProfileToken>"
    res = OnvifCall(mediaUrl, ns.media, "GetStreamUri", inner, ctx)
    res.uri = XmlText(XmlFind(res.response, "Uri"))
    return res
end function

function OnvifGetSnapshotUri(mediaUrl as String, token as String, ctx as Object) as Object
    res = OnvifCall(mediaUrl, OnvifNs().media, "GetSnapshotUri", "<ProfileToken>" + XmlEscape(token) + "</ProfileToken>", ctx)
    res.uri = XmlText(XmlFind(res.response, "Uri"))
    return res
end function

' ---------------------------------------------------------------- probe

' Ports cameras commonly serve ONVIF on: most brands, Reolink, Tapo,
' Xiongmai-based cameras and DVRs, and a few others.
function OnvifCommonPorts() as Object
    return [80, 8000, 2020, 8899, 8080, 5000]
end function

' Returns the device service URL on the first of ports that answers ONVIF
' on host, or "" if none does. skipUrl has already been tried.
function OnvifFindDeviceUrl(host as String, ports as Object, skipUrl as String) as String
    for each port in ports
        url = "http://" + host
        if port <> 80 then url = url + ":" + port.ToStr()
        url = url + "/onvif/device_service"
        if url <> skipUrl and OnvifGetClockOffset(url, 3000).reachable then return url
    end for
    return ""
end function

' Snapshot addresses the common brands serve on their web port, for cameras
' whose ONVIF service doesn't give one. Smaller pictures first where the
' brand offers them. {user} and {pass} are filled in (escaped) for brands
' that take the login in the query string; the others use HTTP auth.
function SnapshotCandidates() as Object
    return [
        "/ISAPI/Streaming/channels/102/picture" ' Hikvision and its OEMs, sub stream
        "/ISAPI/Streaming/channels/101/picture" ' Hikvision, main stream
        "/cgi-bin/snapshot.cgi?channel=1" ' Dahua, Amcrest, Lorex
        "/cgi-bin/api.cgi?cmd=Snap&channel=0&rs=roku&width=640&height=360&user={user}&password={pass}" ' Reolink
        "/images/snapshot.jpg" ' Uniview
        "/axis-cgi/jpg/image.cgi?resolution=640x360" ' Axis
        "/webcapture.jpg?command=snap&channel=1&user={user}&password={pass}" ' Xiongmai-based
        "/cgi-bin/CGIProxy.fcgi?cmd=snapPicture2&usr={user}&pwd={pass}" ' Foscam
        "/snapshot.jpg"
        "/tmpfs/auto.jpg"
    ]
end function

' Tries the snapshot candidates on the camera's ONVIF port and on port 80
' and returns the first URL that serves a JPEG, or "". Stops at the first
' rejected login: some cameras lock out an address after a few.
function OnvifFindSnapshotUrl(deviceUrl as String, user as String, pass as String) as String
    parts = UrlParse(deviceUrl)
    if parts = invalid then return ""
    bases = ["http://" + parts.host]
    if parts.port <> "" and parts.port <> "80" then bases.Unshift("http://" + parts.host + ":" + parts.port)
    file = "tmp:/snapfind_" + SafeKey(parts.host) + ".jpg"
    found = ""
    for each base in bases
        for each path in SnapshotCandidates()
            url = base + path.Replace("{user}", UrlEscape(user)).Replace("{pass}", UrlEscape(pass))
            result = FetchJpeg(url, user, pass, file)
            if result = "jpeg" then found = url
            if result <> "miss" then exit for
        end for
        if found <> "" then exit for
    end for
    DeleteFile(file)
    return found
end function

' Returns "jpeg" if url serves a JPEG, "denied" if the login was refused,
' otherwise "miss".
function FetchJpeg(url as String, user as String, pass as String, file as String) as String
    res = HttpRequest({ url: url, user: user, pass: pass, toFile: file, timeoutMs: 4000 })
    if res.code = 401 and LCase(Left(StrOrEmpty(res.headers["www-authenticate"]), 5)) = "basic" then
        ' The Roku only answers Digest challenges; this one wants Basic.
        res = HttpRequest({ url: url, user: user, pass: pass, basicAuth: true, toFile: file, timeoutMs: 4000 })
    end if
    if res.code = 401 or res.code = 403 then return "denied"
    if res.code <> 200 then return "miss"
    bytes = CreateObject("roByteArray")
    if bytes.ReadFile(file, 0, 2) and bytes.Count() = 2 and bytes[0] = 255 and bytes[1] = 216 then return "jpeg"
    return "miss"
end function

' Talks to one camera and fills in everything the app needs to show it.
' cam: { id, name, xaddr, user, pass, autoPort, wantSnapshots }
'      (user/pass already resolved)
' autoPort: the address was a bare IP, so look for ONVIF on the usual ports
' if xaddr doesn't answer. wantSnapshots (default true): false skips
' looking up snapshot URLs.
' Returns { ok, authFailed, error, info: { deviceUrl, manufacturer, model,
'           timeOffset, mediaUrl, profiles } }.
function OnvifProbeCamera(cam as Object) as Object
    out = { ok: false, authFailed: false, error: "", info: invalid }
    deviceUrl = cam.xaddr
    host = UrlHost(deviceUrl)

    clock = OnvifGetClockOffset(deviceUrl)
    if not clock.reachable and AsBool(cam.autoPort) then
        found = OnvifFindDeviceUrl(host, OnvifCommonPorts(), deviceUrl)
        if found <> "" then
            deviceUrl = found
            clock = OnvifGetClockOffset(deviceUrl)
        end if
    end if
    if not clock.reachable then
        if clock.code > 0 then
            out.error = "No ONVIF service at " + deviceUrl + " (" + clock.error + ")"
        else
            out.error = "Camera not reachable at " + host + " (" + clock.error + ")"
        end if
        return out
    end if
    ctx = { user: StrOrEmpty(cam.user), pass: StrOrEmpty(cam.pass), timeOffset: AsInt(clock.offset) }

    media = OnvifGetMediaUrl(deviceUrl, ctx)
    if not media.ok then
        out.authFailed = media.authFailed
        out.error = media.error
        return out
    end if
    mediaUrl = UrlRehost(media.url, host)

    profiles = OnvifGetProfiles(mediaUrl, ctx)
    if not profiles.ok then
        out.authFailed = profiles.authFailed
        out.error = profiles.error
        return out
    end if

    wantSnapshots = AsBool(cam.wantSnapshots, true)
    hasSnapshot = false
    for each p in profiles.profiles
        stream = OnvifGetStreamUri(mediaUrl, p.token, ctx)
        if stream.ok then p.streamUri = UrlRehost(stream.uri, host)
        if wantSnapshots then
            snap = OnvifGetSnapshotUri(mediaUrl, p.token, ctx)
            if snap.ok and snap.uri <> "" then
                p.snapshotUri = UrlRehost(snap.uri, host)
                hasSnapshot = true
            end if
        end if
    end for
    if wantSnapshots and not hasSnapshot then
        ' Many cameras skip ONVIF snapshots but serve one on their web port.
        url = OnvifFindSnapshotUrl(deviceUrl, ctx.user, ctx.pass)
        for each p in profiles.profiles
            p.snapshotUri = url
        end for
    end if

    info = { deviceUrl: deviceUrl, manufacturer: "", model: "", timeOffset: ctx.timeOffset, mediaUrl: mediaUrl, profiles: profiles.profiles }
    device = OnvifGetDeviceInformation(deviceUrl, ctx)
    if device.ok then
        info.manufacturer = device.info.manufacturer
        info.model = device.info.model
    end if

    out.ok = true
    out.info = info
    return out
end function
