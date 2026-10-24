' Small helpers shared by the render thread and Task threads.

' ---------------------------------------------------------------- strings

function StrOrEmpty(value as Dynamic) as String
    if value = invalid then return ""
    if GetInterface(value, "ifString") <> invalid then return value
    if GetInterface(value, "ifToStr") <> invalid then return value.ToStr()
    return ""
end function

' Comparing invalid with a Boolean is a runtime error on device, so optional
' flags go through this.
function AsBool(value as Dynamic, fallback = false as Boolean) as Boolean
    if value = invalid then return fallback
    if GetInterface(value, "ifBoolean") <> invalid then return value
    return fallback
end function

function AsInt(value as Dynamic, fallback = 0 as Integer) as Integer
    if value = invalid then return fallback
    if GetInterface(value, "ifInt") <> invalid then return value
    if GetInterface(value, "ifFloat") <> invalid or GetInterface(value, "ifDouble") <> invalid then return Int(value)
    if GetInterface(value, "ifString") <> invalid and value.Trim() <> "" then return value.ToInt()
    return fallback
end function

function PadTwo(value as Integer) as String
    if value < 10 then return "0" + value.ToStr()
    return value.ToStr()
end function

function XmlEscape(text as String) as String
    out = text.Replace("&", "&amp;")
    out = out.Replace("<", "&lt;")
    out = out.Replace(">", "&gt;")
    out = out.Replace(Chr(34), "&quot;")
    return out.Replace("'", "&apos;")
end function

' Turns any string into something safe for registry keys, file names and
' bridge path names.
function SafeKey(text as String) as String
    re = CreateObject("roRegex", "[^A-Za-z0-9_-]+", "")
    return re.ReplaceAll(text, "_")
end function

function UrlEscape(text as String) as String
    return CreateObject("roUrlTransfer").Escape(text)
end function

function UrlUnescape(text as String) as String
    return CreateObject("roUrlTransfer").Unescape(text)
end function

' ParseJson logs an error for empty input; registry reads and error bodies
' are often empty.
function ParseJsonSafe(text as Dynamic) as Dynamic
    text = StrOrEmpty(text)
    if text.Trim() = "" then return invalid
    return ParseJson(text)
end function

function Base64OfString(text as String) as String
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(text)
    return bytes.ToBase64String()
end function

' ---------------------------------------------------------------- URLs

' Splits scheme://user:pass@host:port/path?query into its parts. Returns
' invalid when the string is not an absolute URL.
function UrlParse(url as String) as Object
    re = CreateObject("roRegex", "^([A-Za-z][A-Za-z0-9+.-]*)://(?:([^@/?#]*)@)?(\[[^\]]+\]|[^:/?#]+)(?::(\d+))?(.*)$", "")
    m = re.Match(url)
    if m.Count() = 0 then return invalid
    parts = {
        scheme: LCase(m[1])
        userinfo: m[2]
        host: m[3]
        port: m[4]
        rest: m[5]
    }
    return parts
end function

function UrlHost(url as String) as String
    parts = UrlParse(url)
    if parts = invalid then return ""
    return parts.host
end function

function UrlBuild(parts as Object) as String
    url = parts.scheme + "://"
    if parts.userinfo <> "" then url = url + parts.userinfo + "@"
    url = url + parts.host
    if parts.port <> "" then url = url + ":" + parts.port
    return url + parts.rest
end function

' Returns url with its userinfo replaced by the (escaped) credentials.
function UrlWithCredentials(url as String, user as String, pass as String) as String
    parts = UrlParse(url)
    if parts = invalid then return url
    if user = "" then
        parts.userinfo = ""
    else
        parts.userinfo = UrlEscape(user) + ":" + UrlEscape(pass)
    end if
    return UrlBuild(parts)
end function

function IsIpLiteral(host as String) as Boolean
    if Left(host, 1) = "[" then return true
    re = CreateObject("roRegex", "^\d{1,3}(\.\d{1,3}){3}$", "")
    return re.IsMatch(host)
end function

' Cameras often advertise an address other than the one we reached them on
' (a stale static IP, a second interface, a NAT'd container). When a URL the
' camera hands back points at a different IP literal, point it at the host we
' know works and keep the port and path.
function UrlRehost(url as String, knownHost as String) as String
    if knownHost = "" then return url
    parts = UrlParse(url)
    if parts = invalid then return url
    if parts.host = knownHost or not IsIpLiteral(parts.host) then return url
    parts.host = knownHost
    return UrlBuild(parts)
end function

' "192.168.1.20", "192.168.1.20:8080" or a full URL -> device service URL.
function DeviceServiceUrlFor(address as String) as String
    address = address.Trim()
    if address = "" then return ""
    if UrlParse(address) <> invalid then return address
    return "http://" + address + "/onvif/device_service"
end function

' ---------------------------------------------------------------- XML

' roXMLElement keeps namespace prefixes in names ("tt:Uri"); ONVIF devices
' use whatever prefixes they like, so all lookups match on the local name.
function XmlLocalName(name as String) as String
    parts = name.Split(":")
    return parts[parts.Count() - 1]
end function

function XmlParse(text as String) as Object
    if text = invalid or text = "" then return invalid
    xml = CreateObject("roXMLElement")
    if not xml.Parse(text) then return invalid
    return xml
end function

function XmlChildren(node as Object) as Object
    if node = invalid then return []
    kids = node.GetChildElements()
    if kids = invalid then return []
    return kids
end function

' First direct child with the given local name.
function XmlChild(node as Object, localName as String) as Object
    for each child in XmlChildren(node)
        if XmlLocalName(child.GetName()) = localName then return child
    end for
    return invalid
end function

' First descendant (depth first, including node itself) with the local name.
function XmlFind(node as Object, localName as String) as Object
    if node = invalid then return invalid
    if XmlLocalName(node.GetName()) = localName then return node
    for each child in XmlChildren(node)
        found = XmlFind(child, localName)
        if found <> invalid then return found
    end for
    return invalid
end function

function XmlFindAll(node as Object, localName as String, results = invalid as Dynamic) as Object
    if results = invalid then results = []
    if node = invalid then return results
    if XmlLocalName(node.GetName()) = localName then
        results.Push(node)
        return results
    end if
    for each child in XmlChildren(node)
        XmlFindAll(child, localName, results)
    end for
    return results
end function

function XmlText(node as Object) as String
    if node = invalid then return ""
    return StrOrEmpty(node.GetText()).Trim()
end function

' Text of the element found by following a path of local names through
' direct children, e.g. XmlPathText(profile, ["Resolution", "Width"]).
function XmlPathText(node as Object, path as Object) as String
    current = node
    for each name in path
        current = XmlChild(current, name)
        if current = invalid then return ""
    end for
    return XmlText(current)
end function

function XmlAttr(node as Object, name as String) as String
    if node = invalid then return ""
    attrs = node.GetAttributes()
    if attrs = invalid then return ""
    for each key in attrs
        if XmlLocalName(key) = name then return StrOrEmpty(attrs[key])
    end for
    return ""
end function
