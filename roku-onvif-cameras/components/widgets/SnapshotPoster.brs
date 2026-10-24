sub init()
    m.background = m.top.FindNode("background")
    m.front = m.top.FindNode("posterA")
    m.back = m.top.FindNode("posterB")
    m.front.ObserveFieldScoped("loadStatus", "OnLoadStatus")
    m.back.ObserveFieldScoped("loadStatus", "OnLoadStatus")
    m.loading = false
    m.pendingUri = ""
    OnSize()
end sub

sub OnSize()
    w = m.top.width
    h = m.top.height
    m.background.width = w
    m.background.height = h
    for each poster in [m.front, m.back]
        poster.width = w
        poster.height = h
        ' Decode straight to display size: camera JPEGs are often 4K.
        poster.loadWidth = w
        poster.loadHeight = h
    end for
end sub

sub OnUri()
    uri = m.top.uri
    if uri = "" then
        m.front.uri = ""
        m.back.uri = ""
        m.loading = false
        m.pendingUri = ""
        m.top.hasImage = false
        return
    end if
    ' Large pictures can take longer to decode than the refresh interval.
    ' Rather than restarting the decode with every new picture (and never
    ' finishing one), finish it and then jump to the newest.
    if m.loading then
        m.pendingUri = uri
    else
        LoadBack(uri)
    end if
end sub

sub LoadBack(uri as String)
    m.loading = true
    m.back.uri = uri
end sub

sub OnLoadStatus(event as Object)
    poster = event.GetRoSGNode()
    status = event.GetData()
    if not poster.IsSameNode(m.back) or (status <> "ready" and status <> "failed") then return
    m.loading = false
    if status = "ready" then
        m.back.visible = true
        m.front.visible = false
        previous = m.front
        m.front = m.back
        m.back = previous
        m.top.hasImage = true
    end if
    if m.pendingUri <> "" then
        uri = m.pendingUri
        m.pendingUri = ""
        LoadBack(uri)
    end if
end sub
