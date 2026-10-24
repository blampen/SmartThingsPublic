sub init()
    m.grid = m.top.FindNode("grid")
    m.top.ObserveFieldScoped("focusedChild", "OnFocusChanged")
end sub

' The screen itself receives focus from MainScene; hand it to the grid.
sub OnFocusChanged()
    if m.top.HasFocus() then m.grid.SetFocus(true)
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
