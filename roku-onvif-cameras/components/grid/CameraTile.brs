sub init()
    m.snapshot = m.top.FindNode("snapshot")
    m.placeholder = m.top.FindNode("placeholder")
    m.placeholderText = m.top.FindNode("placeholderText")
    m.actionIcon = m.top.FindNode("actionIcon")
    m.statusDot = m.top.FindNode("statusDot")
    m.title = m.top.FindNode("title")
    m.subtitle = m.top.FindNode("subtitle")
    m.content = invalid
    m.snapshot.ObserveFieldScoped("hasImage", "UpdatePlaceholder")
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

    m.title.text = item.title
    if isCamera then
        m.title.translation = [46, 318]
        m.title.width = 300
        m.title.horizAlign = "left"
    else
        m.title.translation = [16, 318]
        m.title.width = 520
        m.title.horizAlign = "center"
    end if
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
