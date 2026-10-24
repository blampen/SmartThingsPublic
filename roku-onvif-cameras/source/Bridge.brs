' Roku cannot play RTSP, and plays one video at a time, so live video goes
' through a MediaMTX server on the LAN (see bridge/). The app registers the
' RTSP URLs of camera N (its position in the list, from 1) as the on-demand
' paths cam<N>_main and cam<N>_sub through the MediaMTX API, then plays:
'   wall      cameras 1-4 in one picture, audio track N = camera N's sound
'   full<N>   camera N alone, for full screen

function BridgeConfigured(settings as Object) as Boolean
    return StrOrEmpty(settings.bridgeHost).Trim() <> ""
end function

function BridgeApiBase(settings as Object) as String
    return "http://" + StrOrEmpty(settings.bridgeHost).Trim() + ":" + AsInt(settings.bridgeApiPort, 9997).ToStr()
end function

function BridgeHlsUrl(settings as Object, pathName as String) as String
    return "http://" + StrOrEmpty(settings.bridgeHost).Trim() + ":" + AsInt(settings.bridgeHlsPort, 8888).ToStr() + "/" + pathName + "/index.m3u8"
end function

' kind is "main" (full screen) or "sub" (the wall).
function BridgeCameraPath(slot as Integer, kind as String) as String
    return "cam" + slot.ToStr() + "_" + kind
end function

function BridgeWallUrl(settings as Object) as String
    return BridgeHlsUrl(settings, "wall")
end function

function BridgeFullUrl(settings as Object, slot as Integer) as String
    return BridgeHlsUrl(settings, "full" + slot.ToStr())
end function

' The wall's audio tracks are cameras 1-4 in order. MediaMTX names them
' after their track number (audio2..audio5, the video being track 1), so
' sort by that number rather than trusting the order the player lists them
' in. Returns the Track id for the camera at position (from 0), or "".
function WallAudioTrack(tracks as Object, position as Integer) as String
    re = CreateObject("roRegex", "(\d+)\s*$", "")
    sorted = []
    for i = 0 to tracks.Count() - 1
        number = i
        match = re.Match(StrOrEmpty(tracks[i].Name))
        if match.Count() > 1 then number = match[1].ToInt()
        entry = { number: number, track: StrOrEmpty(tracks[i].Track) }
        j = sorted.Count()
        while j > 0 and sorted[j - 1].number > number
            j = j - 1
        end while
        sorted.Push(invalid)
        k = sorted.Count() - 1
        while k > j
            sorted[k] = sorted[k - 1]
            k = k - 1
        end while
        sorted[j] = entry
    end for
    if position < 0 or position >= sorted.Count() then return ""
    return sorted[position].track
end function

' Registers each { name, url } in paths; an empty url removes the path, so
' the bridge shows that camera as black instead of a stale stream.
' Re-registering an unchanged path doesn't disturb streams using it.
' Returns { ok, error }.
function BridgeRegisterAll(settings as Object, paths as Object) as Object
    for each path in paths
        if path.url = "" then
            res = BridgeRemove(settings, path.name)
        else
            res = BridgeRegister(settings, path.name, path.url)
        end if
        if not res.ok then return res
    end for
    return { ok: true, error: "" }
end function

function BridgeRemove(settings as Object, pathName as String) as Object
    res = HttpRequest({ url: BridgeApiBase(settings) + "/v3/config/paths/delete/" + pathName, method: "DELETE", timeoutMs: 5000 })
    if HttpIsSuccess(res.code) or res.code = 404 then return { ok: true, error: "" }
    return { ok: false, error: "Bridge: " + BridgeErrorText(res) }
end function

' Creates or replaces the bridge path. Returns { ok, error }.
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
    if HttpIsSuccess(res.code) then return { ok: true, error: "" }
    return { ok: false, error: "Bridge: " + BridgeErrorText(res) }
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
