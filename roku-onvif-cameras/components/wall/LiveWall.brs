sub init()
    m.video = m.top.FindNode("video")
    m.snaps = []
    m.labels = []
    for i = 0 to 3
        poster = m.top.FindNode("snap" + i.ToStr())
        poster.ObserveFieldScoped("hasImage", "UpdateTiles")
        m.snaps.Push(poster)
        m.labels.Push(m.top.FindNode("label" + i.ToStr()))
    end for
    m.highlight = m.top.FindNode("highlight")
    m.tag = m.top.FindNode("tag")
    m.tagBox = m.top.FindNode("tagBox")
    m.speaker = m.top.FindNode("speaker")
    m.hintTimer = m.top.FindNode("hintTimer")
    m.settleTimer = m.top.FindNode("settleTimer")
    m.startTimer = m.top.FindNode("startTimer")
    m.retryTimer = m.top.FindNode("retryTimer")

    m.video.ObserveFieldScoped("state", "OnVideoState")
    m.video.ObserveFieldScoped("availableAudioTracks", "SelectAudio")
    m.hintTimer.ObserveFieldScoped("fire", "HideHint")
    m.settleTimer.ObserveFieldScoped("fire", "StartVideo")
    m.startTimer.ObserveFieldScoped("fire", "OnStartTimeout")
    m.retryTimer.ObserveFieldScoped("fire", "StartVideo")

    m.snapTask = invalid
    m.bridgeTask = invalid
    m.playing = false
    m.pending = false
    m.retryDelay = 5
end sub

sub OnActive()
    if m.top.active then
        m.snapTask = CreateObject("roSGNode", "SnapshotTask")
        m.snapTask.ObserveFieldScoped("frame", "OnFrame")
        m.snapTask.control = "RUN"
        m.retryDelay = 5
        m.pending = BridgeConfigured(m.top.settings)
        UpdateTiles()
        UpdateSnapshotJobs()
        ShowHint()
        ' Register the cameras with the bridge once all of them have
        ' answered (or failed), so their stream addresses are known.
        if m.pending then
            if CamerasSettled() then
                StartVideo()
            else
                m.settleTimer.control = "start"
            end if
        end if
    else
        m.pending = false
        StopVideo()
        CancelBridgeRequest()
        if m.snapTask <> invalid then
            m.snapTask.UnobserveFieldScoped("frame")
            m.snapTask.control = "STOP"
            m.snapTask = invalid
        end if
        for each timer in [m.hintTimer, m.settleTimer, m.startTimer, m.retryTimer]
            timer.control = "stop"
        end for
    end if
end sub

sub OnCameras()
    UpdateTiles()
    UpdateSnapshotJobs()
    UpdateTag()
    if m.pending and m.bridgeTask = invalid and CamerasSettled() then StartVideo()
end sub

function CamerasSettled() as Boolean
    cams = m.top.cameras
    for i = 0 to MinInt(cams.Count(), 4) - 1
        if cams[i].status = "new" or cams[i].status = "probing" then return false
    end for
    return true
end function

' ---------------------------------------------------------------- video

sub StartVideo()
    m.settleTimer.control = "stop"
    m.retryTimer.control = "stop"
    if not m.top.active or not BridgeConfigured(m.top.settings) or m.playing then return
    m.pending = false

    settings = m.top.settings
    cams = m.top.cameras
    paths = []
    for i = 0 to MinInt(cams.Count(), 4) - 1
        paths.Append(CameraBridgePaths(cams[i], i + 1, settings))
    end for

    CancelBridgeRequest()
    m.bridgeTask = CreateObject("roSGNode", "BridgeTask")
    m.bridgeTask.request = { action: "register", settings: settings, paths: paths, hlsUrl: BridgeWallUrl(settings) }
    m.bridgeTask.ObserveFieldScoped("response", "OnBridgeResponse")
    m.bridgeTask.control = "RUN"
    ' The bridge needs a few seconds to open every camera the first time.
    m.startTimer.control = "start"
end sub

sub OnBridgeResponse(event as Object)
    if m.bridgeTask = invalid or not event.GetRoSGNode().IsSameNode(m.bridgeTask) then return
    CancelBridgeRequest()
    res = event.GetData()
    if not res.ok then
        m.startTimer.control = "stop"
        RetryLater()
        return
    end if
    content = CreateObject("roSGNode", "ContentNode")
    content.url = res.hlsUrl
    content.streamFormat = "hls"
    content.live = true
    m.video.content = content
    m.video.control = "play"
end sub

sub OnVideoState()
    state = m.video.state
    if state = "playing" then
        m.startTimer.control = "stop"
        m.playing = true
        m.retryDelay = 5
        ' The video covers the snapshots; stop fetching them.
        m.video.visible = true
        UpdateSnapshotJobs()
        SelectAudio()
        UpdateTag()
        UpdateSpeaker()
    else if state = "error" or state = "finished" then
        ' "finished" means the bridge restarted the wall (e.g. a camera came
        ' back); pick it up again shortly.
        StopVideo()
        RetryLater()
    end if
end sub

sub OnStartTimeout()
    if m.playing then return
    StopVideo()
    CancelBridgeRequest()
    RetryLater()
end sub

sub RetryLater()
    if not m.top.active then return
    m.retryTimer.duration = m.retryDelay
    m.retryTimer.control = "start"
    m.retryDelay = MinInt(m.retryDelay * 2, 60)
end sub

sub StopVideo()
    m.startTimer.control = "stop"
    if m.video.content <> invalid then
        m.video.control = "stop"
        m.video.content = invalid
    end if
    m.video.visible = false
    m.playing = false
    UpdateSnapshotJobs()
    UpdateTag()
    UpdateSpeaker()
end sub

sub CancelBridgeRequest()
    if m.bridgeTask = invalid then return
    m.bridgeTask.UnobserveFieldScoped("response")
    m.bridgeTask = invalid
end sub

' Plays the highlighted camera's audio track.
sub SelectAudio()
    if not m.playing then return
    tracks = m.video.availableAudioTracks
    if tracks = invalid then return
    track = WallAudioTrack(tracks, m.top.focusIndex)
    if track <> "" and m.video.audioTrack <> track then m.video.audioTrack = track
end sub

' ---------------------------------------------------------------- snapshots

sub UpdateSnapshotJobs()
    if m.snapTask = invalid then return
    jobs = []
    if not m.playing then
        cams = m.top.cameras
        settings = m.top.settings
        for i = 0 to MinInt(cams.Count(), 4) - 1
            cam = cams[i]
            url = CameraThumbnailUri(cam, 960)
            if cam.status = "online" and url <> "" then
                login = CameraLogin(cam, settings)
                jobs.Push({ key: "wall" + i.ToStr(), url: url, user: login.user, pass: login.pass, intervalMs: AsInt(settings.refreshSec, 1) * 1000 })
            end if
        end for
    end if
    m.snapTask.jobs = jobs
end sub

sub OnFrame(event as Object)
    frame = event.GetData()
    if not frame.ok then return
    index = AsInt(Mid(frame.key, 5), -1)
    if index >= 0 and index < 4 then m.snaps[index].uri = frame.uri
end sub

' Text shown in a quarter that has no picture yet.
sub UpdateTiles()
    cams = m.top.cameras
    for i = 0 to 3
        text = ""
        if i < cams.Count() and not m.snaps[i].hasImage then
            cam = cams[i]
            text = CameraTitle(cam) + Chr(10)
            if cam.status = "online" and CameraThumbnailUri(cam, 960) <> "" then
                text = text + "Loading picture..."
            else if cam.status = "online" and BridgeConfigured(m.top.settings) then
                text = text + "Starting live video..."
            else if cam.status = "online" then
                text = text + "This camera has no snapshots. Live video needs the video bridge (* then Settings)."
            else if cam.status = "offline" or cam.status = "login" then
                text = text + cam.error
            else
                text = text + "Connecting..."
            end if
        end if
        m.labels[i].text = text
    end for
end sub

' ---------------------------------------------------------------- highlight

function QuarterOrigin(index as Integer) as Object
    return [(index MOD 2) * 960, (index \ 2) * 540]
end function

sub ShowHint()
    m.highlight.translation = QuarterOrigin(m.top.focusIndex)
    UpdateTag()
    m.highlight.visible = true
    m.hintTimer.control = "stop"
    m.hintTimer.control = "start"
    UpdateSpeaker()
end sub

sub HideHint()
    m.highlight.visible = false
end sub

sub UpdateTag()
    cams = m.top.cameras
    index = m.top.focusIndex
    if index >= cams.Count() then return
    cam = cams[index]
    note = "   sound on"
    if cam.status = "offline" then
        note = "   offline"
    else if cam.status = "login" then
        note = "   login failed"
    else if cam.status <> "online" then
        note = "   connecting..."
    else if not BridgeConfigured(m.top.settings) then
        note = "   snapshots (sound needs the video bridge)"
    else if not m.playing then
        note = "   starting live video..."
    end if
    m.tag.text = CameraTitle(cam) + note
    m.tagBox.width = m.tag.BoundingRect().width + 32
end sub

sub UpdateSpeaker()
    m.speaker.visible = m.playing
    origin = QuarterOrigin(m.top.focusIndex)
    m.speaker.translation = [origin[0] + 960 - 88, origin[1] + 20]
end sub

sub MoveFocus(key as String)
    index = m.top.focusIndex
    col = index MOD 2
    row = index \ 2
    if key = "left" then col = 0
    if key = "right" then col = 1
    if key = "up" then row = 0
    if key = "down" then row = 1
    target = row * 2 + col
    if target < m.top.cameras.Count() then m.top.focusIndex = target
    SelectAudio()
    ShowHint()
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "left" or key = "right" or key = "up" or key = "down" then
        MoveFocus(key)
    else if key = "OK" then
        m.top.selected = m.top.focusIndex
    else if key = "options" then
        m.top.optionsPressed = m.top.focusIndex
    else
        ' Back falls through: on the home screen it exits the channel.
        return false
    end if
    return true
end function
