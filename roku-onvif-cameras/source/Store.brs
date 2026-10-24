' Settings and the saved camera list. The registry is capped at 16 KB per
' channel, so only what cannot be rediscovered is stored; stream and
' snapshot URIs are fetched from each camera at startup.

function StoreSection() as Object
    return CreateObject("roRegistrySection", "onvifcams")
end function

function DefaultSettings() as Object
    return {
        user: "admin"
        pass: ""
        bridgeHost: ""
        bridgeApiPort: 9997
        bridgeHlsPort: 8888
        refreshSec: 3
        preferVideo: true
    }
end function

' Defaults, then any settings from presets.json, then what the user saved.
function LoadSettings() as Object
    settings = DefaultSettings()
    presets = LoadPresets()
    if presets <> invalid then settings.Append(presets.settings)
    saved = ParseJsonSafe(StoreSection().Read("settings"))
    if saved <> invalid and GetInterface(saved, "ifAssociativeArray") <> invalid then settings.Append(saved)
    return settings
end function

sub SaveSettings(settings as Object)
    section = StoreSection()
    section.Write("settings", FormatJson(settings))
    section.Flush()
end sub

' Saved cameras: [{ id, name, xaddr, ownLogin, user, pass, profile }]
' ownLogin false means "use the default login from Settings".
function LoadCameras() as Object
    saved = ParseJsonSafe(StoreSection().Read("cameras"))
    cameras = []
    if saved = invalid or GetInterface(saved, "ifArray") = invalid then return cameras
    for each item in saved
        if GetInterface(item, "ifAssociativeArray") <> invalid and StrOrEmpty(item.xaddr) <> "" then
            cameras.Push(NewCameraRecord(item))
        end if
    end for
    return cameras
end function

sub SaveCameras(cameras as Object)
    stored = []
    for each cam in cameras
        stored.Push({
            id: cam.id
            name: cam.name
            xaddr: cam.xaddr
            ownLogin: cam.ownLogin
            user: cam.user
            pass: cam.pass
            profile: cam.profile
        })
    end for
    section = StoreSection()
    section.Write("cameras", FormatJson(stored))
    section.Flush()
end sub

' Optional fixed camera list baked into the package as pkg:/presets.json
' (see presets.example.json). It holds passwords, so it is kept out of git.
' Returns invalid when there is no presets file with cameras in it.
function LoadPresets() as Dynamic
    return ParsePresets(ReadAsciiFile("pkg:/presets.json"))
end function

' { cameras: [camera records], settings: {} }
function ParsePresets(text as String) as Dynamic
    data = ParseJsonSafe(text)
    if data = invalid or GetInterface(data, "ifAssociativeArray") = invalid then return invalid
    list = data.cameras
    if list = invalid or GetInterface(list, "ifArray") = invalid then return invalid

    cameras = []
    for each item in list
        address = ""
        if GetInterface(item, "ifAssociativeArray") <> invalid then address = StrOrEmpty(item.address).Trim()
        if address <> "" then
            user = StrOrEmpty(data.user)
            pass = StrOrEmpty(data.pass)
            if item.user <> invalid then user = StrOrEmpty(item.user)
            if item.pass <> invalid then pass = StrOrEmpty(item.pass)
            cam = NewCameraRecord({ id: "preset:" + address, name: StrOrEmpty(item.name), xaddr: DeviceServiceUrlFor(address), ownLogin: true, user: user, pass: pass })
            ' A bare IP doesn't say which port ONVIF is on; let the probe look.
            cam.autoPort = UrlParse(address) = invalid and address.InStr(":") < 0
            cameras.Push(cam)
        end if
    end for
    if cameras.Count() = 0 then return invalid

    settings = {}
    if data.settings <> invalid and GetInterface(data.settings, "ifAssociativeArray") <> invalid then settings = data.settings
    return { cameras: cameras, settings: settings }
end function

' Preset cameras keep what the app learned about them (the ONVIF port it
' found, the stream picked) across launches.
function ApplySavedCameraState(presets as Object, saved as Object) as Object
    for each cam in presets
        for each old in saved
            if old.id = cam.id then
                cam.xaddr = old.xaddr
                cam.profile = old.profile
            end if
        end for
    end for
    return presets
end function

sub ClearStore()
    section = StoreSection()
    for each key in section.GetKeyList()
        section.Delete(key)
    end for
    section.Flush()
end sub

' Normalises a saved or discovered camera into the record the app passes
' around. Runtime fields (status, profiles, ...) start empty.
function NewCameraRecord(src as Object) as Object
    xaddr = StrOrEmpty(src.xaddr)
    id = StrOrEmpty(src.id)
    if id = "" then id = "host:" + UrlHost(xaddr)
    return {
        id: id
        name: StrOrEmpty(src.name)
        xaddr: xaddr
        ownLogin: AsBool(src.ownLogin)
        user: StrOrEmpty(src.user)
        pass: StrOrEmpty(src.pass)
        profile: AsInt(src.profile)
        status: "new"
        error: ""
        model: ""
        profiles: []
    }
end function

function CameraLogin(cam as Object, settings as Object) as Object
    if AsBool(cam.ownLogin) then return { user: StrOrEmpty(cam.user), pass: StrOrEmpty(cam.pass) }
    return { user: StrOrEmpty(settings.user), pass: StrOrEmpty(settings.pass) }
end function

function CameraTitle(cam as Object) as String
    if StrOrEmpty(cam.name) <> "" then return cam.name
    if StrOrEmpty(cam.model) <> "" then return cam.model
    return UrlHost(StrOrEmpty(cam.xaddr))
end function

' The profile used for full screen viewing, clamped to what the camera has.
function CameraProfile(cam as Object) as Object
    profiles = cam.profiles
    if profiles = invalid or profiles.Count() = 0 then return invalid
    index = AsInt(cam.profile)
    if index < 0 or index >= profiles.Count() then index = 0
    return profiles[index]
end function

' Thumbnails come from the smallest profile at least minWidth wide (or the
' largest there is): enough detail for the tile, far less to download and
' decode than the main stream.
function CameraThumbnailUri(cam as Object, minWidth = 0 as Integer) as String
    profiles = cam.profiles
    if profiles = invalid then return ""
    best = invalid
    largest = invalid
    for each p in profiles
        if StrOrEmpty(p.snapshotUri) <> "" then
            if p.width >= minWidth and (best = invalid or p.width < best.width) then best = p
            if largest = invalid or p.width > largest.width then largest = p
        end if
    end for
    if best <> invalid then return best.snapshotUri
    if largest <> invalid then return largest.snapshotUri
    return ""
end function

function ProfileLabel(profile as Object) as String
    label = ""
    if profile.width > 0 then label = profile.width.ToStr() + "x" + profile.height.ToStr()
    if profile.encoding <> "" then label = label + " " + profile.encoding
    if profile.fps > 0 then label = label + " " + profile.fps.ToStr() + "fps"
    if profile.name <> "" then label = label + " (" + profile.name + ")"
    return label.Trim()
end function
