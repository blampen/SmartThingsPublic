' Roku cannot play RTSP, so full motion video goes through a MediaMTX server
' on the LAN (see bridge/). Before playing, the app registers the camera's
' RTSP URL as an on-demand MediaMTX path through its control API and then
' plays that path's HLS output.

function BridgeConfigured(settings as Object) as Boolean
    return StrOrEmpty(settings.bridgeHost).Trim() <> ""
end function

function BridgeApiBase(settings as Object) as String
    return "http://" + StrOrEmpty(settings.bridgeHost).Trim() + ":" + AsInt(settings.bridgeApiPort, 9997).ToStr()
end function

function BridgeHlsUrl(settings as Object, pathName as String) as String
    return "http://" + StrOrEmpty(settings.bridgeHost).Trim() + ":" + AsInt(settings.bridgeHlsPort, 8888).ToStr() + "/" + pathName + "/index.m3u8"
end function

function BridgePathName(cameraId as String, profileToken as String) as String
    return "roku_" + SafeKey(cameraId + "_" + profileToken)
end function

' Creates or replaces the bridge path. Returns { ok, hlsUrl, error }.
function BridgeRegister(settings as Object, pathName as String, rtspUrl as String) as Object
    ' MediaMTX rejects keys in the wrong case, and BrightScript lowercases
    ' keys set with dot notation, so build the body with AddReplace.
    config = {}
    config.AddReplace("source", rtspUrl)
    config.AddReplace("sourceOnDemand", true)
    config.AddReplace("rtspTransport", "tcp")
    res = HttpRequest({
        url: BridgeApiBase(settings) + "/v3/config/paths/replace/" + pathName
        method: "POST"
        body: FormatJson(config)
        headers: { "Content-Type": "application/json" }
        timeoutMs: 5000
    })
    if HttpIsSuccess(res.code) then return { ok: true, hlsUrl: BridgeHlsUrl(settings, pathName), error: "" }
    return { ok: false, hlsUrl: "", error: "Bridge: " + BridgeErrorText(res) }
end function

' Returns { ok, version, error }.
function BridgeInfo(settings as Object) as Object
    res = HttpRequest({ url: BridgeApiBase(settings) + "/v3/info", timeoutMs: 4000 })
    if HttpIsSuccess(res.code) then
        info = ParseJsonSafe(res.body)
        version = ""
        if info <> invalid then version = StrOrEmpty(info.version)
        return { ok: true, version: version, error: "" }
    end if
    return { ok: false, version: "", error: BridgeErrorText(res) }
end function

function BridgeErrorText(res as Object) as String
    if res.code = 401 or res.code = 403 then return "API access denied - allow this Roku in mediamtx.yml (authInternalUsers)"
    parsed = ParseJsonSafe(res.body)
    if parsed <> invalid and GetInterface(parsed, "ifAssociativeArray") <> invalid and StrOrEmpty(parsed.error) <> "" then return parsed.error
    if res.code <= 0 then return "not reachable (" + HttpErrorText(res) + ")"
    return HttpErrorText(res)
end function
