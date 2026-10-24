' StandardDialog plumbing shared by components that show dialogs. The
' including component implements:
'   OnDialogResult(purpose, button, text, data)  button is -1 when dismissed
'   DialogFocusTarget()                          node to refocus afterwards

sub ShowMessageDialog(title as String, lines as Object, buttons as Object, purpose as String, data = invalid as Dynamic)
    dialog = CreateObject("roSGNode", "StandardMessageDialog")
    dialog.title = title
    dialog.message = lines
    dialog.buttons = buttons
    OpenDialog(dialog, purpose, data)
end sub

sub ShowKeyboardDialog(title as String, lines as Object, text as String, secure as Boolean, purpose as String, data = invalid as Dynamic)
    dialog = CreateObject("roSGNode", "StandardKeyboardDialog")
    dialog.title = title
    dialog.message = lines
    dialog.text = text
    dialog.buttons = ["OK", "Cancel"]
    if secure then
        dialog.keyboardDomain = "password"
        dialog.textEditBox.secureMode = true
    end if
    OpenDialog(dialog, purpose, data)
end sub

sub OpenDialog(dialog as Object, purpose as String, data as Dynamic)
    DetachDialog()
    m.dialog = dialog
    m.dialogPurpose = purpose
    m.dialogData = data
    dialog.ObserveFieldScoped("buttonSelected", "OnDialogButton")
    dialog.ObserveFieldScoped("wasClosed", "OnDialogClosed")
    m.top.GetScene().dialog = dialog
end sub

' Stops listening to the open dialog and dismisses it.
sub DetachDialog()
    if m.dialog = invalid then return
    dialog = m.dialog
    m.dialog = invalid
    dialog.UnobserveFieldScoped("buttonSelected")
    dialog.UnobserveFieldScoped("wasClosed")
    dialog.close = true
end sub

sub OnDialogButton()
    if m.dialog = invalid then return
    button = m.dialog.buttonSelected
    text = ""
    if m.dialog.HasField("text") then text = m.dialog.text
    FinishDialog(button, text)
end sub

' Back, Home or Options dismissed the dialog.
sub OnDialogClosed()
    if m.dialog = invalid then return
    FinishDialog(-1, "")
end sub

sub FinishDialog(button as Integer, text as String)
    purpose = m.dialogPurpose
    data = m.dialogData
    DetachDialog()
    DialogFocusTarget().SetFocus(true)
    OnDialogResult(purpose, button, text, data)
end sub
