sub init()
    m.snapshot = m.top.FindNode("snapshot")
    m.placeholder = m.top.FindNode("placeholder")
    m.placeholderText = m.top.FindNode("placeholderText")
    m.actionIcon = m.top.FindNode("actionIcon")
    m.statusDot = m.top.FindNode("statusDot")
    m.title = m.top.FindNode("title")
    m.subtitle = m.top.FindNode("subtitle")
    m.card = m.top.FindNode("card")
    m.labelStrip = m.top.FindNode("labelStrip")
    m.content = invalid
    m.layout = ""
    m.snapshot.ObserveFieldScoped("hasImage", "UpdatePlaceholder")
    ApplyLayout("grid", true)
end sub

' grid: 552 x 368 with the name below the picture.
' wall: 924 x 520 (a quarter of the screen) with the name over the picture.
sub ApplyLayout(layout as String, isCamera as Boolean)
    key = layout + isCamera.ToStr()
    if key = m.layout then return
    m.layout = key

    if layout = "wall" then
        w = 924
        h = 520
        pictureHeight = h
        labelY = h - 60
        labelHeight = 60
        m.title.font = "font:MediumBoldSystemFont"
        m.subtitle.font = "font:SmallSystemFont"
        m.placeholderText.font = "font:SmallSystemFont"
    else
        w = 552
        h = 368
        pictureHeight = 310
        labelY = 314
        labelHeight = 50
        m.title.font = "font:SmallBoldSystemFont"
        m.subtitle.font = "font:SmallestSystemFont"
        m.placeholderText.font = "font:SmallestSystemFont"
    end if

    m.card.width = w
    m.card.height = h
    m.snapshot.width = w
    m.snapshot.height = pictureHeight
    m.placeholder.translation = [(w - 160) / 2, pictureHeight / 2 - 110]
    m.placeholderText.translation = [24, pictureHeight / 2 + 60]
    m.placeholderText.width = w - 48
    m.labelStrip.visible = layout = "wall"
    m.labelStrip.translation = [0, labelY]
    m.labelStrip.width = w
    m.labelStrip.height = labelHeight
    m.statusDot.translation = [20, labelY + (labelHeight - 16) / 2]
    m.title.height = labelHeight
    m.subtitle.height = labelHeight
    m.subtitle.translation = [w * 0.62, labelY]
    m.subtitle.width = w * 0.38 - 20
    if isCamera then
        m.title.translation = [48, labelY]
        m.title.width = w * 0.62 - 56
        m.title.horizAlign = "left"
    else
        m.title.translation = [16, labelY]
        m.title.width = w - 32
        m.title.horizAlign = "center"
    end if
end sub

' Tiles are recycled as the grid scrolls, so re-point the observers at
' whichever item this tile now shows.
sub OnContent()
    if m.content <> invalid then
        for each field in ["title", "status", "statusText", "snapshotUri", "snapshotError"]
            m.content.UnobserveFieldScoped(field)
        end for
    end if
    m.content = m.top.itemContent
    if m.content = invalid then return
    for each field in ["title", "status", "statusText", "snapshotUri", "snapshotError"]
        m.content.ObserveFieldScoped(field, "Render")
    end for
    m.snapshot.uri = ""
    Render()
end sub

sub Render()
    item = m.content
    if item = invalid then return
    isCamera = item.kind = "camera"
    ApplyLayout(item.layout, isCamera)

    m.title.text = item.title
    m.snapshot.visible = isCamera
    m.actionIcon.visible = not isCamera
    m.statusDot.visible = isCamera
    m.subtitle.text = item.statusText

    if isCamera then
        m.statusDot.color = StatusColor(item.status)
        if item.snapshotUri <> "" and item.snapshotUri <> m.snapshot.uri then m.snapshot.uri = item.snapshotUri
        if item.status <> "online" then m.snapshot.uri = ""
    else
        m.actionIcon.uri = item.icon
    end if
    UpdatePlaceholder()
end sub

sub UpdatePlaceholder()
    item = m.content
    if item = invalid then return
    showing = item.kind = "camera" and not m.snapshot.hasImage
    m.placeholder.visible = showing
    m.placeholderText.visible = showing
    if not showing then return

    if item.snapshotError <> "" then
        m.placeholderText.text = item.snapshotError
    else if item.status = "online" then
        m.placeholderText.text = "Loading picture..."
    else if item.status = "login" then
        m.placeholderText.text = "Press OK to enter the camera's login"
    else
        m.placeholderText.text = "Connecting..."
    end if
end sub
