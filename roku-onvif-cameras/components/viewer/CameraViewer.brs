sub init()
    m.video = m.top.FindNode("video")
    m.snapshot = m.top.FindNode("snapshot")
    m.spinner = m.top.FindNode("spinner")
    m.message = m.top.FindNode("message")
    m.overlay = m.top.FindNode("overlay")
    m.name = m.top.FindNode("name")
    m.detail = m.top.FindNode("detail")
    m.clock = m.top.FindNode("clock")
    m.overlayTimer = m.top.FindNode("overlayTimer")
    m.clockTimer = m.top.FindNode("clockTimer")
    m.retryTimer = m.top.FindNode("retryTimer")
    m.startTimer = m.top.FindNode("startTimer")

    m.spinner.poster.uri = "pkg:/images/spinner.png"
    m.spinner.poster.width = 96
    m.spinner.poster.height = 96
    m.spinner.spinInterval = 1

    m.video.ObserveFieldScoped("state", "OnVideoState")
    m.overlayTimer.ObserveFieldScoped("fire", "HideOverlay")
    m.clockTimer.ObserveFieldScoped("fire", "UpdateClock")
    m.retryTimer.ObserveFieldScoped("fire", "OnRetry")
    m.startTimer.ObserveFieldScoped("fire", "OnStartTimeout")
    m.clock12 = CreateObject("roDeviceInfo").GetClockFormat() = "12h"

    m.cameras = []
    m.snapTask = invalid
    m.bridgeTask = invalid
    m.snapKey = ""
    m.mode = ""
    m.forceSnapshots = false
    m.videoRetries = 0
end sub

sub OnActive()
    if m.top.active then
        m.cameras = m.top.cameras
        m.forceSnapshots = not AsBool(m.top.settings.preferVideo, true)
        m.snapTask = CreateObject("roSGNode", "SnapshotTask")
        m.snapTask.ObserveFieldScoped("frame", "OnFrame")
        m.snapTask.control = "RUN"
        m.clockTimer.control = "start"
        UpdateClock()
        ShowCamera()
    else
        StopVideo()
        CancelBridgeRequest()
        if m.snapTask <> invalid then
            m.snapTask.UnobserveFieldScoped("frame")
            m.snapTask.control = "STOP"
            m.snapTask = invalid
        end if
        m.clockTimer.control = "stop"
        m.overlayTimer.control = "stop"
        m.retryTimer.control = "stop"
        m.startTimer.control = "stop"
        m.snapshot.uri = ""
    end if
end sub

function CurrentCamera() as Object
    return m.cameras[m.top.index]
end function

' (Re)starts viewing the current camera in the current mode.
sub ShowCamera()
    StopVideo()
    CancelBridgeRequest()
    m.retryTimer.control = "stop"
    m.snapshot.uri = ""
    m.message.text = ""
    m.videoRetries = 0

    cam = CurrentCamera()
    profile = CameraProfile(cam)
    position = m.top.index + 1
    m.name.text = CameraTitle(cam) + "   " + position.ToStr() + "/" + m.cameras.Count().ToStr()
    ShowOverlay()

    if cam.status <> "online" or profile = invalid then
        m.mode = ""
        SetSnapshotJob("", 0)
        m.detail.text = cam.xaddr
        reason = StrOrEmpty(cam.error)
        if cam.status = "login" then reason = "This camera needs its login. Press Back, then OK on the camera to enter it."
        if reason = "" then reason = "Still connecting to this camera..."
        ShowMessage(reason)
        return
    end if

    if not m.forceSnapshots and BridgeConfigured(m.top.settings) and profile.streamUri <> "" then
        StartVideo(cam, profile)
    else
        note = "snapshots"
        if not m.forceSnapshots and not BridgeConfigured(m.top.settings) then note = "snapshots (set up the video bridge in Settings for live video)"
        StartSnapshots(note)
    end if
end sub

' ---------------------------------------------------------------- video

sub StartVideo(cam as Object, profile as Object)
    m.mode = "video"
    ' Show snapshots while the bridge connects so the screen is never blank.
    SetSnapshotJob(SnapshotUrlFor(cam, profile), 1000)
    SetSpinner(true)
    m.detail.text = ProfileLabel(profile) + "   connecting to live video..."
    m.startTimer.control = "start"

    login = CameraLogin(cam, m.top.settings)
    rtspUrl = profile.streamUri
    if login.user <> "" then rtspUrl = UrlWithCredentials(rtspUrl, login.user, login.pass)

    m.bridgeTask = CreateObject("roSGNode", "BridgeTask")
    m.bridgeTask.request = {
        action: "register"
        settings: m.top.settings
        pathName: BridgePathName(cam.id, profile.token)
        rtspUrl: rtspUrl
    }
    m.bridgeTask.ObserveFieldScoped("response", "OnBridgeResponse")
    m.bridgeTask.control = "RUN"
end sub

sub OnBridgeResponse(event as Object)
    if m.bridgeTask = invalid or not event.GetRoSGNode().IsSameNode(m.bridgeTask) then return
    CancelBridgeRequest()
    res = event.GetData()
    if not res.ok then
        FallBackToSnapshots(res.error)
        return
    end if

    content = CreateObject("roSGNode", "ContentNode")
    content.url = res.hlsUrl
    content.streamFormat = "hls"
    content.live = true
    content.title = CameraTitle(CurrentCamera())
    m.video.content = content
    m.video.visible = true
    m.video.control = "play"
end sub

sub OnVideoState()
    if m.mode <> "video" then return
    state = m.video.state
    if state = "playing" then
        m.startTimer.control = "stop"
        SetSpinner(false)
        m.snapshot.visible = false
        m.message.text = ""
        SetSnapshotJob("", 0)
        m.videoRetries = 0
        m.detail.text = ProfileLabel(CameraProfile(CurrentCamera())) + "   live video"
    else if state = "buffering" then
        SetSpinner(true)
    else if state = "error" then
        ' The first request after registering can race the bridge's
        ' connection to the camera; one quick retry covers it.
        if m.videoRetries < 1 then
            m.videoRetries = m.videoRetries + 1
            RestartVideoSoon()
        else
            FallBackToSnapshots(VideoErrorText())
        end if
    else if state = "finished" then
        ' A live stream "finishes" when the bridge or camera drops it.
        RestartVideoSoon()
    end if
end sub

function VideoErrorText() as String
    text = m.video.errorMsg
    if text = "" then text = "video error " + m.video.errorCode.ToStr()
    return "Live video failed: " + text
end function

sub RestartVideoSoon()
    m.video.control = "stop"
    SetSpinner(true)
    m.retryTimer.control = "start"
end sub

sub OnRetry()
    if m.mode <> "video" then return
    m.startTimer.control = "start"
    if m.video.content <> invalid then
        m.video.control = "play"
    else
        ShowCamera()
    end if
end sub

sub OnStartTimeout()
    if m.mode = "video" and m.video.state <> "playing" then FallBackToSnapshots("live video didn't start (check the bridge log)")
end sub

sub StopVideo()
    m.startTimer.control = "stop"
    if m.video.content <> invalid then
        m.video.control = "stop"
        m.video.content = invalid
    end if
    m.video.visible = false
    m.snapshot.visible = true
    SetSpinner(false)
end sub

sub CancelBridgeRequest()
    if m.bridgeTask = invalid then return
    m.bridgeTask.UnobserveFieldScoped("response")
    m.bridgeTask = invalid
end sub

sub FallBackToSnapshots(reason as String)
    StopVideo()
    StartSnapshots("snapshots - " + reason)
    ShowOverlay()
end sub

' ---------------------------------------------------------------- snapshots

sub StartSnapshots(note as String)
    m.mode = "snapshot"
    cam = CurrentCamera()
    profile = CameraProfile(cam)
    url = SnapshotUrlFor(cam, profile)
    m.detail.text = ProfileLabel(profile) + "   " + note
    if url = "" then
        SetSnapshotJob("", 0)
        ShowMessage("This camera does not provide snapshots. Live video needs the video bridge (see Settings).")
        return
    end if
    if not m.snapshot.hasImage then SetSpinner(true)
    ' Back to back requests: as close to video as snapshots get.
    SetSnapshotJob(url, 250)
end sub

function SnapshotUrlFor(cam as Object, profile as Object) as String
    if profile <> invalid and StrOrEmpty(profile.snapshotUri) <> "" then return profile.snapshotUri
    return CameraThumbnailUri(cam)
end function

sub SetSnapshotJob(url as String, intervalMs as Integer)
    if m.snapTask = invalid then return
    if url = "" then
        m.snapKey = ""
        m.snapTask.jobs = []
        return
    end if
    cam = CurrentCamera()
    login = CameraLogin(cam, m.top.settings)
    m.snapKey = "view_" + cam.id
    m.snapTask.jobs = [{ key: m.snapKey, url: url, user: login.user, pass: login.pass, intervalMs: intervalMs }]
end sub

sub OnFrame(event as Object)
    frame = event.GetData()
    if frame.key <> m.snapKey then return
    if frame.ok then
        m.snapshot.uri = frame.uri
        m.message.text = ""
        if m.mode = "snapshot" then SetSpinner(false)
    else if not m.snapshot.hasImage and m.mode = "snapshot" then
        SetSpinner(false)
        ShowMessage(frame.error)
    end if
end sub

' ---------------------------------------------------------------- overlay

sub ShowMessage(text as String)
    m.message.text = text
    ShowOverlay()
end sub

sub SetSpinner(visible as Boolean)
    m.spinner.visible = visible
    if visible then
        m.spinner.control = "start"
    else
        m.spinner.control = "stop"
    end if
end sub

sub ShowOverlay()
    m.overlay.visible = true
    m.overlayTimer.control = "stop"
    m.overlayTimer.control = "start"
end sub

sub HideOverlay()
    m.overlay.visible = false
end sub

sub UpdateClock()
    now = CreateObject("roDateTime")
    now.ToLocalTime()
    hours = now.GetHours()
    if m.clock12 then
        suffix = " AM"
        if hours >= 12 then suffix = " PM"
        hours = hours MOD 12
        if hours = 0 then hours = 12
        m.clock.text = hours.ToStr() + ":" + PadTwo(now.GetMinutes()) + ":" + PadTwo(now.GetSeconds()) + suffix
    else
        m.clock.text = PadTwo(hours) + ":" + PadTwo(now.GetMinutes()) + ":" + PadTwo(now.GetSeconds())
    end if
end sub

' ---------------------------------------------------------------- keys

sub SwitchCamera(delta as Integer)
    count = m.cameras.Count()
    if count < 2 then return
    m.top.index = (m.top.index + delta + count) MOD count
    ShowCamera()
end sub

' Profiles are sorted best first, so "up" means a lower index.
sub ChangeProfile(delta as Integer)
    cam = CurrentCamera()
    count = cam.profiles.Count()
    if count < 2 then
        m.detail.text = "This camera has only one stream"
        ShowOverlay()
        return
    end if
    index = AsInt(cam.profile)
    if index < 0 or index >= count then index = 0
    cam.profile = (index + delta + count) MOD count
    m.top.profileChanged = { id: cam.id, profile: cam.profile }
    ShowCamera()
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "back" then
        m.top.active = false
        m.top.closed = true
    else if key = "left" then
        SwitchCamera(-1)
    else if key = "right" then
        SwitchCamera(1)
    else if key = "up" then
        ChangeProfile(-1)
    else if key = "down" then
        ChangeProfile(1)
    else if key = "options" then
        m.forceSnapshots = not m.forceSnapshots
        ShowCamera()
    else if key = "replay" then
        ShowCamera()
    else if key = "OK" then
        if m.overlay.visible then
            HideOverlay()
        else
            ShowOverlay()
        end if
    else
        return false
    end if
    return true
end function
