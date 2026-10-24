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
    m.top.ObserveFieldScoped("cameras", "OnCameras")
    device = CreateObject("roDeviceInfo")
    m.clock12 = device.GetClockFormat() = "12h"
    m.canHevc = AsBool(device.CanDecodeVideo({ Codec: "hevc" }).result)

    m.cameras = []
    m.snapTask = invalid
    m.bridgeTask = invalid
    m.snapKey = ""
    m.mode = ""
    m.forceSnapshots = false
    m.videoRetries = 0
    m.retryDelay = 5
    m.waitingForCamera = false
    m.hints = m.top.FindNode("hints")
end sub

sub OnActive()
    if m.top.active then
        m.cameras = m.top.cameras
        m.retryDelay = 5
        if m.top.allowSnapshots then
            m.forceSnapshots = not AsBool(m.top.settings.preferVideo, true)
            m.snapTask = CreateObject("roSGNode", "SnapshotTask")
            m.snapTask.ObserveFieldScoped("frame", "OnFrame")
            m.snapTask.control = "RUN"
            m.hints.text = "Left / Right  camera        Up / Down  stream quality        *  video / snapshots        OK  hide info        Replay  reconnect"
        else
            m.forceSnapshots = false
            m.hints.text = "Left / Right  camera        Up / Down  stream quality        OK  hide info        Replay  reconnect        Back  all cameras"
        end if
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
        m.waitingForCamera = false
    end if
end sub

function CurrentCamera() as Object
    return m.cameras[m.top.index]
end function

' Updated camera records while open: start the camera that was still
' connecting as soon as it answers.
sub OnCameras()
    if not m.top.active or not m.waitingForCamera then return
    cams = m.top.cameras
    if m.top.index >= cams.Count() then return
    m.cameras = cams
    if CurrentCamera().status <> "new" and CurrentCamera().status <> "probing" then ShowCamera()
end sub

' (Re)starts viewing the current camera in the current mode.
sub ShowCamera()
    StopVideo()
    CancelBridgeRequest()
    m.retryTimer.control = "stop"
    m.snapshot.uri = ""
    m.message.text = ""
    m.videoRetries = 0
    m.waitingForCamera = false

    cam = CurrentCamera()
    profile = CameraProfile(cam)
    position = m.top.index + 1
    m.name.text = CameraTitle(cam) + "   " + position.ToStr() + "/" + m.cameras.Count().ToStr()
    ShowOverlay()

    if cam.status <> "online" or profile = invalid then
        m.mode = ""
        m.waitingForCamera = cam.status = "new" or cam.status = "probing"
        SetSnapshotJob("", 0)
        m.detail.text = cam.xaddr
        reason = StrOrEmpty(cam.error)
        if reason = "" then reason = "Still connecting to this camera..."
        ShowMessage(reason)
        return
    end if

    if m.forceSnapshots then
        StartSnapshots("snapshots")
    else if not BridgeConfigured(m.top.settings) then
        NoVideo("Live video needs the video bridge. Press Back, then * and Settings, and enter the bridge's IP address.", "snapshots (set up the video bridge in Settings for live video)")
    else if IsHevc(profile) and not m.canHevc then
        NoVideo("This TV can't decode H.265 video. Set the camera's main stream to H.264.", "snapshots - this TV can't decode H.265; set the camera's main stream to H.264")
    else if profile.streamUri = "" then
        NoVideo("The camera didn't report a video stream address.", "snapshots")
    else
        StartVideo(cam, profile)
    end if
end sub

' Live video isn't possible for this camera: show snapshots where they're
' allowed, otherwise say why.
sub NoVideo(message as String, snapshotNote as String)
    if m.top.allowSnapshots then
        StartSnapshots(snapshotNote)
        return
    end if
    m.mode = ""
    m.detail.text = ProfileLabel(CameraProfile(CurrentCamera()))
    ShowMessage(message)
end sub

' ---------------------------------------------------------------- video

sub StartVideo(cam as Object, profile as Object)
    m.mode = "video"
    ' Where snapshots are allowed, show them while the bridge connects.
    SetSnapshotJob(SnapshotUrlFor(cam, profile), 1000)
    SetSpinner(true)
    m.detail.text = ProfileLabel(profile) + "   connecting to live video..."
    m.startTimer.control = "start"

    ' The bridge's full<N> path plays camera N's cam<N>_main stream.
    slot = m.top.index + 1
    m.bridgeTask = CreateObject("roSGNode", "BridgeTask")
    m.bridgeTask.request = {
        action: "register"
        settings: m.top.settings
        paths: [{ name: BridgeCameraPath(slot, "main"), url: CameraRtspUrl(cam, profile, m.top.settings) }]
        hlsUrl: BridgeFullUrl(m.top.settings, slot)
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
        m.retryDelay = 5
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
    m.retryTimer.duration = 3
    m.retryTimer.control = "start"
end sub

' Live video only: say what went wrong and start over after a pause that
' grows while it keeps failing.
sub RetryVideo(reason as String)
    StopVideo()
    CancelBridgeRequest()
    m.mode = "video"
    ShowMessage(reason + Chr(10) + "Trying again...")
    m.retryTimer.duration = m.retryDelay
    m.retryTimer.control = "start"
    m.retryDelay = MinInt(m.retryDelay * 2, 30)
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
    if m.mode = "video" and m.video.state <> "playing" then FallBackToSnapshots("Live video didn't start (check the bridge log)")
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
    if not m.top.allowSnapshots then
        RetryVideo(reason)
        return
    end if
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
        if m.top.allowSnapshots then
            m.forceSnapshots = not m.forceSnapshots
            ShowCamera()
        end if
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
