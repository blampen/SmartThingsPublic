sub init()
    m.grid = m.top.FindNode("grid")
    m.header = m.top.FindNode("header")
    m.top.ObserveFieldScoped("focusedChild", "OnFocusChanged")
end sub

' The screen itself receives focus from MainScene; hand it to the grid.
sub OnFocusChanged()
    if m.top.HasFocus() then m.grid.SetFocus(true)
end sub

' The wall fills a 1920 x 1080 screen with four 16:9 tiles, leaving room at
' the edges for the focus ring.
sub OnLayout()
    wall = m.top.layout = "wall"
    m.header.visible = not wall
    if wall then
        m.grid.translation = [28, 14]
        m.grid.numColumns = 2
        m.grid.numRows = 2
        m.grid.itemSize = [924, 520]
        m.grid.itemSpacing = [16, 12]
    else
        m.grid.translation = [96, 172]
        m.grid.numColumns = 3
        m.grid.numRows = 2
        m.grid.itemSize = [552, 368]
        m.grid.itemSpacing = [36, 44]
    end if
end sub

sub OnJumpToItem()
    m.grid.jumpToItem = m.top.jumpToItem
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "options" then
        m.top.optionsPressed = m.grid.itemFocused
        return true
    end if
    return false
end function
