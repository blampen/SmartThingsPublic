sub init()
    m.list = m.top.FindNode("list")
    m.help = m.top.FindNode("help")
    m.list.ObserveFieldScoped("itemSelected", "OnSelected")
    m.list.ObserveFieldScoped("itemFocused", "OnFocused")
    m.top.ObserveFieldScoped("focusedChild", "OnFocusChanged")
    m.bridgeTask = invalid
    m.refreshChoices = [1, 2, 3, 5, 10, 30]

    info = CreateObject("roAppInfo")
    m.top.FindNode("version").text = info.GetTitle() + " " + info.GetVersion() + "   -   Roku " + CreateObject("roDeviceInfo").GetModel()
    m.settings = LoadSettings()
    BuildList()
end sub

sub OnFocusChanged()
    if m.top.HasFocus() then
        m.settings = LoadSettings()
        BuildList()
        m.list.SetFocus(true)
    end if
end sub

sub BuildList()
    s = m.settings
    password = "no password"
    if s.pass <> "" then password = "password set"
    fixed = LoadPresets() <> invalid
    bridge = "not set (snapshots only)"
    if fixed then bridge = "not set - needed for live video"
    if BridgeConfigured(s) then bridge = s.bridgeHost
    mode = "snapshots"
    if s.preferVideo then mode = "live video"

    m.items = [
        { id: "login", text: "Default camera login:  " + s.user + "  (" + password + ")", help: "Used for every camera that doesn't have its own login. This is the camera's ONVIF user - on many cameras ONVIF users are set up separately from the web admin login." }
        { id: "bridge", text: "Video bridge:  " + bridge, help: "Roku players can't play the RTSP streams cameras send, so live video and sound go through the bridge (MediaMTX) running on a computer or NAS on your network. Enter its IP address. The project README has a one-command Docker setup." + Chr(10) + Chr(10) + "Without a bridge, cameras are shown as quickly refreshed snapshots, without sound." }
        { id: "ports", text: "Bridge ports:  API " + AsInt(s.bridgeApiPort).ToStr() + ",  HLS " + AsInt(s.bridgeHlsPort).ToStr(), help: "Only change these if you changed apiAddress or hlsAddress in mediamtx.yml. Defaults: 9997 and 8888." }
        { id: "test", text: "Test video bridge", help: "Checks that this Roku can reach the bridge's API." }
        { id: "mode", text: "Open cameras in:  " + mode, help: "What full screen view starts with. Press * while watching to switch between live video and snapshots." }
        { id: "refresh", text: "Thumbnail refresh:  every " + AsInt(s.refreshSec).ToStr() + " s", help: "How often the camera grid fetches a new picture from each camera." }
        { id: "clear", text: "Remove all cameras", help: "Forgets every camera. Search again from the home screen to find them." }
    ]
    if fixed then
        ' Cameras and their logins come from presets.json in the package.
        fixedItems = []
        for each item in m.items
            if item.id = "bridge" or item.id = "ports" or item.id = "test" then fixedItems.Push(item)
        end for
        m.items = fixedItems
    end if
    content = CreateObject("roSGNode", "ContentNode")
    for each item in m.items
        node = content.CreateChild("ContentNode")
        node.title = item.text
    end for
    focused = m.list.itemFocused
    m.list.content = content
    if focused > 0 and focused < m.items.Count() then m.list.jumpToItem = focused
    OnFocused()
end sub

sub OnFocused()
    index = m.list.itemFocused
    if index >= 0 and index < m.items.Count() then m.help.text = m.items[index].help
end sub

sub Save()
    SaveSettings(m.settings)
    BuildList()
    m.top.changed = true
end sub

sub OnSelected()
    id = m.items[m.list.itemSelected].id
    s = m.settings
    if id = "login" then
        ShowKeyboardDialog("Default camera login", ["Username"], s.user, false, "user")
    else if id = "bridge" then
        ShowKeyboardDialog("Video bridge", ["IP address of the computer running MediaMTX.", "Leave empty to use snapshots only."], s.bridgeHost, false, "bridge")
    else if id = "ports" then
        ShowKeyboardDialog("Bridge API port", ["MediaMTX apiAddress port (default 9997)"], AsInt(s.bridgeApiPort).ToStr(), false, "apiPort")
    else if id = "test" then
        TestBridge()
    else if id = "mode" then
        s.preferVideo = not s.preferVideo
        Save()
    else if id = "refresh" then
        choice = m.refreshChoices[0]
        for i = 0 to m.refreshChoices.Count() - 2
            if m.refreshChoices[i] = AsInt(s.refreshSec) then choice = m.refreshChoices[i + 1]
        end for
        s.refreshSec = choice
        Save()
    else if id = "clear" then
        ShowMessageDialog("Remove all cameras?", ["The default login and bridge settings are kept."], ["Remove all", "Cancel"], "clear")
    end if
end sub

sub OnDialogResult(purpose as String, button as Integer, text as String, data as Dynamic)
    if button <> 0 then return
    s = m.settings
    text = text.Trim()
    if purpose = "user" then
        ShowKeyboardDialog("Default camera login", ["Password for " + text], s.pass, true, "pass", { user: text })
    else if purpose = "pass" then
        s.user = data.user
        s.pass = text
        Save()
    else if purpose = "bridge" then
        ' Accept a pasted URL like http://192.168.1.10:8888/ too.
        host = text
        if UrlParse(host) <> invalid then host = UrlHost(host)
        s.bridgeHost = host.Split(":")[0]
        Save()
    else if purpose = "apiPort" then
        ShowKeyboardDialog("Bridge HLS port", ["MediaMTX hlsAddress port (default 8888)"], AsInt(s.bridgeHlsPort).ToStr(), false, "hlsPort", { api: AsInt(text, 9997) })
    else if purpose = "hlsPort" then
        s.bridgeApiPort = ValidPort(data.api, 9997)
        s.bridgeHlsPort = ValidPort(AsInt(text, 8888), 8888)
        Save()
    else if purpose = "clear" then
        m.top.clearCameras = true
    end if
end sub

function ValidPort(port as Integer, fallback as Integer) as Integer
    if port < 1 or port > 65535 then return fallback
    return port
end function

function DialogFocusTarget() as Object
    return m.list
end function

sub TestBridge()
    if not BridgeConfigured(m.settings) then
        ShowMessageDialog("Video bridge", ["Enter the bridge's IP address first."], ["OK"], "info")
        return
    end if
    m.bridgeTask = CreateObject("roSGNode", "BridgeTask")
    m.bridgeTask.request = { action: "info", settings: m.settings }
    m.bridgeTask.ObserveFieldScoped("response", "OnTestResult")
    m.bridgeTask.control = "RUN"
    m.help.text = "Contacting " + BridgeApiBase(m.settings) + " ..."
end sub

sub OnTestResult(event as Object)
    res = event.GetData()
    m.bridgeTask.UnobserveFieldScoped("response")
    m.bridgeTask = invalid
    OnFocused()
    if res.ok then
        lines = ["Connected to MediaMTX " + res.version + " at " + m.settings.bridgeHost + ".", "Live video will play through it."]
        ShowMessageDialog("Video bridge works", lines, ["OK"], "info")
    else
        lines = [res.error, "Check that MediaMTX is running with the mediamtx.yml from this project, and that port " + AsInt(m.settings.bridgeApiPort).ToStr() + " is reachable from this Roku."]
        ShowMessageDialog("Can't reach the video bridge", lines, ["OK"], "info")
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if press and key = "back" then
        m.top.closed = true
        return true
    end if
    return false
end function
