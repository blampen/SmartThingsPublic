' Colours shared by the components (0xRRGGBBAA).

function Theme() as Object
    return {
        background: "0x0F1318FF"
        tile: "0x1C232BFF"
        accent: "0x3FA9F5FF"
        text: "0xFFFFFFFF"
        dim: "0x9AA7B4FF"
        ok: "0x5DD39EFF"
        warn: "0xF5B83FFF"
        bad: "0xFF6B6BFF"
        idle: "0x6E7A88FF"
    }
end function

function StatusColor(status as String) as String
    t = Theme()
    if status = "online" then return t.ok
    if status = "login" then return t.warn
    if status = "offline" then return t.bad
    return t.idle
end function
