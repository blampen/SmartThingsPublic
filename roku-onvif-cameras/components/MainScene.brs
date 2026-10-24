' Owns the camera list: discovery, probing, thumbnails, and moving between
' the home screen, the full screen viewer and settings. The home screen is
' the camera grid, or with presets.json the four-feed LiveWall.
'
' Loops over m.cameras use indexes: a "for each" shares the array's single
' iterator, so a helper that also walks m.cameras would end the outer loop.

sub init()
    m.grid = m.top.FindNode("grid")
    m.wall = m.top.FindNode("wall")
    m.viewer = m.top.FindNode("viewer")
    m.settingsScreen = m.top.FindNode("settingsScreen")
    m.toast = m.top.FindNode("toast")
    m.toastLabel = m.top.FindNode("toastLabel")
    m.toastTimer = m.top.FindNode("toastTimer")

    m.settings = LoadSettings()
    ' presets.json in the package fixes the camera list (see README).
    presets = LoadPresets()
    m.fixed = presets <> invalid
    if m.fixed then
        m.cameras = ApplySavedCameraState(presets.cameras, LoadCameras())
    else
        m.cameras = LoadCameras()
    end if
    m.items = {}
    m.probeTasks = {}
    m.probeGen = 0
    m.discovery = invalid
    m.screen = "grid"

    m.grid.ObserveFieldScoped("itemSelected", "OnGridSelected")
    m.grid.ObserveFieldScoped("optionsPressed", "OnGridOptions")
    m.wall.ObserveFieldScoped("selected", "OnWallSelected")
    m.wall.ObserveFieldScoped("optionsPressed", "OnWallOptions")
    m.viewer.ObserveFieldScoped("closed", "OnViewerClosed")
    m.viewer.ObserveFieldScoped("profileChanged", "OnProfileChanged")
    m.settingsScreen.ObserveFieldScoped("closed", "OnSettingsClosed")
    m.settingsScreen.ObserveFieldScoped("changed", "OnSettingsChanged")
    m.settingsScreen.ObserveFieldScoped("clearCameras", "OnClearCameras")
    m.toastTimer.ObserveFieldScoped("fire", "HideToast")

    ' Grid thumbnails. Fixed cameras are live video only: no snapshots.
    m.snapTask = invalid
    if not m.fixed then
        m.snapTask = CreateObject("roSGNode", "SnapshotTask")
        m.snapTask.ObserveFieldScoped("frame", "OnGridFrame")
        m.snapTask.control = "RUN"
    end if

    if m.fixed then
        m.grid.visible = false
        m.wall.visible = true
        m.wall.settings = m.settings
        m.wall.cameras = m.cameras
        m.wall.active = true
        m.wall.SetFocus(true)
    else
        BuildGrid(0)
        m.grid.SetFocus(true)
    end if
    m.top.SignalBeacon("AppLaunchComplete")

    if m.fixed then
        ProbeCameras(false)
        ShowToast("Arrows  pick camera and sound          OK  full screen          *  options")
    else if m.cameras.Count() = 0 then
        StartDiscovery()
    else
        ProbeCameras(false)
    end if
end sub

' ---------------------------------------------------------------- grid

sub BuildGrid(focusIndex as Integer)
    content = CreateObject("roSGNode", "ContentNode")
    m.items = {}
    for i = 0 to m.cameras.Count() - 1
        cam = m.cameras[i]
        item = content.CreateChild("CameraItem")
        item.kind = "camera"
        item.camId = cam.id
        m.items[cam.id] = item
        UpdateItem(cam)
    end for
    AddAction(content, "scan", "Search for cameras", "pkg:/images/tile_scan.png")
    AddAction(content, "add", "Add camera by address", "pkg:/images/tile_add.png")
    AddAction(content, "settings", "Settings", "pkg:/images/tile_settings.png")
    m.grid.content = content
    if focusIndex > 0 and focusIndex < content.GetChildCount() then m.grid.jumpToItem = focusIndex
    UpdateGridStatus()
    UpdateSnapshotJobs()
end sub

sub AddAction(content as Object, kind as String, title as String, icon as String)
    item = content.CreateChild("CameraItem")
    item.kind = kind
    item.title = title
    item.icon = icon
end sub

sub UpdateItem(cam as Object)
    item = m.items[cam.id]
    if item = invalid then return
    item.title = CameraTitle(cam)
    item.status = cam.status
    if cam.status = "online" then
        profile = CameraProfile(cam)
        item.statusText = "Online"
        if profile <> invalid and profile.width > 0 then item.statusText = profile.width.ToStr() + "x" + profile.height.ToStr()
        if CameraThumbnailUri(cam, 552) = "" then
            item.snapshotError = "No snapshots from this camera - press OK for live video"
        else if item.snapshotError.InStr("No snapshots") = 0 then
            item.snapshotError = ""
        end if
    else if cam.status = "login" then
        item.statusText = "Login needed"
        item.snapshotError = ""
    else if cam.status = "offline" then
        item.statusText = "Offline"
        item.snapshotError = cam.error
    else
        item.statusText = "Connecting"
        item.snapshotError = ""
    end if
end sub

sub UpdateGridStatus()
    online = 0
    for i = 0 to m.cameras.Count() - 1
        if m.cameras[i].status = "online" then online = online + 1
    end for
    text = m.cameras.Count().ToStr() + " cameras, " + online.ToStr() + " online"
    if m.cameras.Count() = 0 then text = "No cameras yet"
    if m.discovery <> invalid then text = text + "   -   searching the network..."
    m.grid.statusText = text
end sub

' Grid thumbnails refresh only while the grid is on screen (the LiveWall
' fetches its own).
sub UpdateSnapshotJobs()
    jobs = []
    if m.screen = "grid" and not m.fixed then
        interval = AsInt(m.settings.refreshSec, 3) * 1000
        for i = 0 to m.cameras.Count() - 1
            cam = m.cameras[i]
            url = CameraThumbnailUri(cam, 552)
            if cam.status = "online" and url <> "" then
                login = CameraLogin(cam, m.settings)
                jobs.Push({ key: cam.id, url: url, user: login.user, pass: login.pass, intervalMs: interval })
            end if
        end for
    end if
    if m.snapTask <> invalid then m.snapTask.jobs = jobs
end sub

sub OnGridFrame(event as Object)
    frame = event.GetData()
    item = m.items[frame.key]
    if item = invalid then return
    if frame.ok then
        item.snapshotUri = frame.uri
        item.snapshotError = ""
    else
        item.snapshotError = frame.error
    end if
end sub

sub OnGridSelected()
    item = m.grid.content.GetChild(m.grid.itemSelected)
    if item = invalid then return
    if item.kind = "scan" then
        StartDiscovery()
    else if item.kind = "add" then
        ShowKeyboardDialog("Add camera", ["Camera IP address, optionally with the ONVIF port:", "192.168.1.64   or   192.168.1.64:8000"], "", false, "addHost")
    else if item.kind = "settings" then
        OpenSettings()
    else
        cam = FindCamera(item.camId)
        if cam <> invalid then SelectCamera(cam)
    end if
end sub

sub OnWallSelected()
    index = m.wall.selected
    if index >= 0 and index < m.cameras.Count() then SelectCamera(m.cameras[index])
end sub

sub SelectCamera(cam as Object)
    if cam.status = "online" then
        OpenViewer(cam)
    else if m.fixed and (cam.status = "login" or cam.status = "offline") then
        ' Fixed cameras' logins and addresses come from presets.json.
        ShowMessageDialog(CameraTitle(cam), [cam.error, cam.xaddr], ["Try again", "Cancel"], "offline", { id: cam.id, actions: ["reconnect"] })
    else if cam.status = "login" then
        StartLogin(cam)
    else if cam.status = "offline" then
        ShowMessageDialog(CameraTitle(cam), [cam.error, cam.xaddr], ["Try again", "Camera login", "Change address", "Remove camera", "Cancel"], "offline", { id: cam.id, actions: ["reconnect", "login", "address", "remove"] })
    else
        ShowToast("Still connecting to " + CameraTitle(cam) + "...")
    end if
end sub

sub OnGridOptions()
    item = m.grid.content.GetChild(m.grid.optionsPressed)
    if item = invalid or item.kind <> "camera" then return
    cam = FindCamera(item.camId)
    if cam <> invalid then ShowCameraMenu(cam)
end sub

sub OnWallOptions()
    index = m.wall.optionsPressed
    if index >= 0 and index < m.cameras.Count() then ShowCameraMenu(m.cameras[index])
end sub

sub ShowCameraMenu(cam as Object)
    buttons = []
    actions = []
    if cam.status = "online" then
        buttons.Push("Watch")
        actions.Push("watch")
    end if
    if cam.profiles.Count() > 1 then
        buttons.Push("Stream: " + ProfileLabel(CameraProfile(cam)))
        actions.Push("stream")
    end if
    if m.fixed then
        buttons.Push("Reconnect")
        actions.Push("reconnect")
        buttons.Push("Settings")
        actions.Push("settings")
    else
        buttons.Push("Rename")
        actions.Push("rename")
        if cam.ownLogin then
            buttons.Push("Login: " + cam.user + " (this camera)")
        else
            buttons.Push("Login: default")
        end if
        actions.Push("login")
        if cam.ownLogin then
            buttons.Push("Use the default login")
            actions.Push("defaultLogin")
        end if
        buttons.Push("Change address")
        actions.Push("address")
        buttons.Push("Reconnect")
        actions.Push("reconnect")
        buttons.Push("Remove camera")
        actions.Push("remove")
    end if

    lines = [cam.xaddr]
    if cam.model <> "" then lines.Unshift(cam.model)
    if cam.status <> "online" and cam.error <> "" then lines.Push(cam.error)
    ShowMessageDialog(CameraTitle(cam), lines, buttons, "camMenu", { id: cam.id, actions: actions })
end sub

' ---------------------------------------------------------------- cameras

function FindCamera(id as String) as Dynamic
    index = CameraIndex(id)
    if index < 0 then return invalid
    return m.cameras[index]
end function

function CameraIndex(id as String) as Integer
    for i = 0 to m.cameras.Count() - 1
        if m.cameras[i].id = id then return i
    end for
    return -1
end function

' Probes every camera, or only those using the default login that aren't
' working yet.
sub ProbeCameras(failingDefaultLoginOnly as Boolean)
    for i = 0 to m.cameras.Count() - 1
        cam = m.cameras[i]
        if not failingDefaultLoginOnly or (not cam.ownLogin and cam.status <> "online") then ProbeCamera(cam)
    end for
end sub

sub ProbeCamera(cam as Object)
    ' A newer probe supersedes any still running for this camera.
    m.probeGen = m.probeGen + 1
    cam.probeGen = m.probeGen
    cam.status = "probing"
    cam.error = ""
    UpdateItem(cam)
    UpdateGridStatus()
    CamerasChanged()

    login = CameraLogin(cam, m.settings)
    task = CreateObject("roSGNode", "OnvifTask")
    task.camera = { id: cam.id, xaddr: cam.xaddr, autoPort: AsBool(cam.autoPort), wantSnapshots: not m.fixed, user: login.user, pass: login.pass, gen: cam.probeGen }
    task.ObserveFieldScoped("result", "OnProbeResult")
    task.control = "RUN"
    m.probeTasks[cam.probeGen.ToStr()] = task
end sub

sub OnProbeResult(event as Object)
    res = event.GetData()
    key = AsInt(res.gen).ToStr()
    task = m.probeTasks[key]
    if task <> invalid then
        task.UnobserveFieldScoped("result")
        m.probeTasks.Delete(key)
    end if

    cam = FindCamera(res.id)
    if cam = invalid or AsInt(cam.probeGen) <> AsInt(res.gen) then return
    if res.ok then
        cam.status = "online"
        cam.error = ""
        cam.profiles = res.info.profiles
        model = res.info.manufacturer + " " + res.info.model
        cam.model = model.Trim()
        if res.info.deviceUrl <> cam.xaddr then
            ' Found ONVIF on another port; remember it for next time.
            cam.xaddr = res.info.deviceUrl
            SaveCameras(m.cameras)
        end if
    else if res.authFailed then
        cam.status = "login"
        cam.error = res.error
    else
        cam.status = "offline"
        cam.error = res.error
    end if
    UpdateItem(cam)
    UpdateGridStatus()
    UpdateSnapshotJobs()
    CamerasChanged()
end sub

' The LiveWall works on a copy of the list; hand it the latest.
sub CamerasChanged()
    if m.fixed then m.wall.cameras = m.cameras
    if m.screen = "viewer" then m.viewer.cameras = m.cameras
end sub

sub AddCamera(src as Object)
    cam = NewCameraRecord(src)
    m.cameras.Push(cam)
    SaveCameras(m.cameras)
    BuildGrid(m.cameras.Count() - 1)
    ProbeCamera(cam)
end sub

sub RemoveCamera(id as String)
    index = CameraIndex(id)
    if index < 0 then return
    m.cameras.Delete(index)
    SaveCameras(m.cameras)
    BuildGrid(index)
end sub

' ---------------------------------------------------------------- discovery

sub StartDiscovery()
    if m.discovery <> invalid then return
    m.discovery = CreateObject("roSGNode", "DiscoveryTask")
    m.discovery.ObserveFieldScoped("results", "OnDiscoveryResults")
    m.discovery.control = "RUN"
    UpdateGridStatus()
    ShowToast("Searching your network for ONVIF cameras...")
end sub

sub OnDiscoveryResults(event as Object)
    results = event.GetData()
    m.discovery.UnobserveFieldScoped("results")
    m.discovery = invalid

    added = []
    moved = []
    for each found in results
        cam = FindCamera(found.id)
        if cam = invalid then cam = FindCameraByHost(found.host)
        if cam = invalid then
            cam = NewCameraRecord({ id: found.id, name: found.name, xaddr: found.xaddr })
            m.cameras.Push(cam)
            added.Push(cam)
        else if cam.xaddr <> found.xaddr and cam.status <> "online" then
            ' The camera moved (new DHCP lease); follow it.
            cam.xaddr = found.xaddr
            moved.Push(cam)
        end if
    end for

    if added.Count() + moved.Count() > 0 then
        SaveCameras(m.cameras)
        BuildGrid(m.grid.itemFocused)
        for each cam in added
            ProbeCamera(cam)
        end for
        for each cam in moved
            ProbeCamera(cam)
        end for
    end if
    UpdateGridStatus()

    if results.Count() = 0 then
        lines = ["Make sure ONVIF is turned on in each camera's settings, and that the cameras and this Roku are on the same network (discovery doesn't cross VLANs or subnets).", "You can also add a camera by its IP address."]
        ShowMessageDialog("No cameras found", lines, ["Add by address", "OK"], "noneFound")
    else
        ShowToast("Found " + results.Count().ToStr() + " ONVIF devices, " + added.Count().ToStr() + " new")
    end if
end sub

function FindCameraByHost(host as String) as Dynamic
    for i = 0 to m.cameras.Count() - 1
        if UrlHost(m.cameras[i].xaddr) = host then return m.cameras[i]
    end for
    return invalid
end function

' ---------------------------------------------------------------- login

sub StartLogin(cam as Object)
    login = CameraLogin(cam, m.settings)
    lines = ["Username for " + CameraTitle(cam), "Use the camera's ONVIF user. Some cameras (Reolink, Amcrest, Tapo...) need ONVIF or a separate ONVIF account turned on first."]
    ShowKeyboardDialog("Camera login", lines, login.user, false, "loginUser", { id: cam.id })
end sub

sub ApplyLogin(cam as Object, user as String, pass as String, allCameras as Boolean)
    if allCameras then
        m.settings.user = user
        m.settings.pass = pass
        SaveSettings(m.settings)
        wasOnline = cam.status = "online"
        cam.ownLogin = false
        SaveCameras(m.cameras)
        ProbeCameras(true)
        if wasOnline then ProbeCamera(cam)
    else
        cam.ownLogin = true
        cam.user = user
        cam.pass = pass
        SaveCameras(m.cameras)
        ProbeCamera(cam)
    end if
end sub

' ---------------------------------------------------------------- dialogs

sub OnDialogResult(purpose as String, button as Integer, text as String, data as Dynamic)
    if purpose = "noneFound" then
        if button = 0 then ShowKeyboardDialog("Add camera", ["Camera IP address, optionally with the ONVIF port:", "192.168.1.64   or   192.168.1.64:8000"], "", false, "addHost")
        return
    end if
    if button < 0 then return

    if purpose = "addHost" then
        if button = 0 and text.Trim() <> "" then AddCameraByAddress(text.Trim())
        return
    end if

    cam = invalid
    if data <> invalid and data.id <> invalid then cam = FindCamera(data.id)
    if cam = invalid then return

    if purpose = "camMenu" or purpose = "offline" then
        if button >= data.actions.Count() then return
        RunCameraAction(cam, data.actions[button])
    else if purpose = "loginUser" then
        if button <> 0 then return
        data.user = text.Trim()
        ShowKeyboardDialog("Camera login", ["Password for " + data.user], "", true, "loginPass", data)
    else if purpose = "loginPass" then
        if button <> 0 then return
        data.pass = text
        if m.cameras.Count() = 1 then
            ApplyLogin(cam, data.user, data.pass, true)
        else
            ShowMessageDialog("Use this login for", ["Make it the default login for all cameras, or use it for " + CameraTitle(cam) + " only?"], ["All cameras", "This camera only", "Cancel"], "loginScope", data)
        end if
    else if purpose = "loginScope" then
        if button = 0 then ApplyLogin(cam, data.user, data.pass, true)
        if button = 1 then ApplyLogin(cam, data.user, data.pass, false)
    else if purpose = "rename" then
        if button <> 0 then return
        cam.name = text.Trim()
        SaveCameras(m.cameras)
        UpdateItem(cam)
    else if purpose = "address" then
        if button <> 0 or text.Trim() = "" then return
        cam.xaddr = DeviceServiceUrlFor(text)
        SaveCameras(m.cameras)
        ProbeCamera(cam)
    else if purpose = "remove" then
        if button = 0 then RemoveCamera(cam.id)
    end if
end sub

sub RunCameraAction(cam as Object, action as String)
    if action = "watch" then
        OpenViewer(cam)
    else if action = "stream" then
        count = cam.profiles.Count()
        cam.profile = (AsInt(cam.profile) + 1) MOD count
        SaveCameras(m.cameras)
        UpdateItem(cam)
        ShowToast("Full screen stream: " + ProfileLabel(CameraProfile(cam)))
    else if action = "rename" then
        ShowKeyboardDialog("Rename camera", ["Leave empty to use the name the camera reports."], cam.name, false, "rename", { id: cam.id })
    else if action = "login" then
        StartLogin(cam)
    else if action = "defaultLogin" then
        cam.ownLogin = false
        SaveCameras(m.cameras)
        ProbeCamera(cam)
    else if action = "address" then
        ShowKeyboardDialog("Camera address", ["IP address with optional port, or the full ONVIF device service URL."], cam.xaddr, false, "address", { id: cam.id })
    else if action = "reconnect" then
        ProbeCamera(cam)
    else if action = "settings" then
        OpenSettings()
    else if action = "remove" then
        ShowMessageDialog("Remove " + CameraTitle(cam) + "?", ["Search again or add it by address to bring it back."], ["Remove", "Cancel"], "remove", { id: cam.id })
    end if
end sub

sub AddCameraByAddress(address as String)
    xaddr = DeviceServiceUrlFor(address)
    host = UrlHost(xaddr)
    if host = "" then
        ShowToast("That doesn't look like an address: " + address)
        return
    end if
    existing = FindCameraByHost(host)
    if existing <> invalid then
        existing.xaddr = xaddr
        SaveCameras(m.cameras)
        ProbeCamera(existing)
        ShowToast(CameraTitle(existing) + " is already in the list - reconnecting")
        return
    end if
    AddCamera({ id: "host:" + host, xaddr: xaddr })
end sub

function DialogFocusTarget() as Object
    if m.screen = "viewer" then return m.viewer
    if m.screen = "settings" then return m.settingsScreen
    return HomeScreen()
end function

function HomeScreen() as Object
    if m.fixed then return m.wall
    return m.grid
end function

' Shows the home screen again. The Roku plays one video at a time, so the
' LiveWall only runs while it's on screen.
sub ShowHome()
    m.screen = "grid"
    if m.fixed then
        m.wall.settings = m.settings
        m.wall.visible = true
        m.wall.active = true
    else
        m.grid.visible = true
    end if
    HomeScreen().SetFocus(true)
    UpdateSnapshotJobs()
end sub

sub HideHome()
    if m.fixed then m.wall.active = false
    HomeScreen().visible = false
end sub

' ---------------------------------------------------------------- screens

sub OpenViewer(cam as Object)
    m.screen = "viewer"
    UpdateSnapshotJobs()
    m.viewer.settings = m.settings
    m.viewer.allowSnapshots = not m.fixed
    m.viewer.cameras = m.cameras
    m.viewer.index = CameraIndex(cam.id)
    HideHome()
    m.viewer.visible = true
    m.viewer.active = true
    m.viewer.SetFocus(true)
end sub

sub OnViewerClosed()
    m.viewer.active = false
    m.viewer.visible = false
    ' Come back to the camera that was on screen.
    index = m.viewer.index
    if m.fixed then
        if index < 4 then m.wall.focusIndex = index
    else
        m.grid.jumpToItem = index
    end if
    ShowHome()
end sub

sub OnProfileChanged(event as Object)
    change = event.GetData()
    cam = FindCamera(change.id)
    if cam = invalid then return
    cam.profile = change.profile
    SaveCameras(m.cameras)
    UpdateItem(cam)
    CamerasChanged()
end sub

sub OpenSettings()
    m.screen = "settings"
    UpdateSnapshotJobs()
    HideHome()
    m.settingsScreen.visible = true
    m.settingsScreen.SetFocus(true)
end sub

sub OnSettingsClosed()
    m.settingsScreen.visible = false
    ShowHome()
end sub

sub OnSettingsChanged()
    previous = m.settings
    m.settings = LoadSettings()
    if previous.user <> m.settings.user or previous.pass <> m.settings.pass then ProbeCameras(true)
end sub

sub OnClearCameras()
    m.cameras = []
    SaveCameras(m.cameras)
    BuildGrid(0)
    ShowToast("All cameras removed")
end sub

' ---------------------------------------------------------------- toast

sub ShowToast(text as String)
    m.toastLabel.text = text
    m.toast.visible = true
    m.toastTimer.control = "stop"
    m.toastTimer.control = "start"
end sub

sub HideToast()
    m.toast.visible = false
end sub
