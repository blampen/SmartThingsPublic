sub init()
    m.background = m.top.FindNode("background")
    m.front = m.top.FindNode("posterA")
    m.back = m.top.FindNode("posterB")
    m.front.ObserveFieldScoped("loadStatus", "OnLoadStatus")
    m.back.ObserveFieldScoped("loadStatus", "OnLoadStatus")
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
        m.top.hasImage = false
        return
    end if
    m.back.uri = uri
end sub

sub OnLoadStatus(event as Object)
    poster = event.GetRoSGNode()
    if not poster.IsSameNode(m.back) or event.GetData() <> "ready" then return
    m.back.visible = true
    m.front.visible = false
    previous = m.front
    m.front = m.back
    m.back = previous
    m.top.hasImage = true
end sub
