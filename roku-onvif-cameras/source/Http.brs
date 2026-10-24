' Blocking HTTP helpers for Task threads (never call these on the render
' thread). Each request gets its own message port so a timeout is exact.

' opts: url, method ("GET" default), body, headers (AA), user, pass,
'       basicAuth (send credentials preemptively as HTTP Basic instead of
'       answering a Digest challenge), toFile (GET into this path),
'       timeoutMs (default 8000)
' Returns { code, body, reason }. code is the HTTP status, a negative curl
' error, or 0 when the request timed out.
function HttpRequest(opts as Object) as Object
    xfer = HttpNewTransfer(opts)
    port = CreateObject("roMessagePort")
    xfer.SetMessagePort(port)

    if not HttpStart(xfer, opts) then return { code: -1, body: "", reason: "Could not start request" }

    msg = wait(AsInt(opts.timeoutMs, 8000), port)
    if type(msg) = "roUrlEvent" then
        return { code: msg.GetResponseCode(), body: StrOrEmpty(msg.GetString()), reason: StrOrEmpty(msg.GetFailureReason()) }
    end if
    xfer.AsyncCancel()
    return { code: 0, body: "", reason: "Timed out" }
end function

function HttpNewTransfer(opts as Object) as Object
    xfer = CreateObject("roUrlTransfer")
    xfer.SetUrl(opts.url)
    xfer.RetainBodyOnError(true)
    xfer.EnableEncodings(true)
    if LCase(Left(opts.url, 6)) = "https:" then
        xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
        ' Cameras and the bridge live on the LAN and almost always use
        ' self-signed certificates.
        xfer.EnablePeerVerification(false)
        xfer.EnableHostVerification(false)
    end if

    user = StrOrEmpty(opts.user)
    if user <> "" then
        pass = StrOrEmpty(opts.pass)
        if AsBool(opts.basicAuth) then
            xfer.AddHeader("Authorization", "Basic " + Base64OfString(user + ":" + pass))
        else
            ' Answers HTTP Digest challenges (Roku never sends Basic here).
            xfer.SetUserAndPassword(user, pass)
        end if
    end if

    if opts.headers <> invalid then
        for each name in opts.headers
            xfer.AddHeader(name, opts.headers[name])
        end for
    end if
    return xfer
end function

' Starts an async transfer described by opts on an already configured
' roUrlTransfer. Returns false if the request could not be issued.
function HttpStart(xfer as Object, opts as Object) as Boolean
    method = "GET"
    if opts.method <> invalid then method = UCase(opts.method)

    if method = "GET" then
        if opts.toFile <> invalid then return xfer.AsyncGetToFile(opts.toFile)
        return xfer.AsyncGetToString()
    end if

    if method <> "POST" then xfer.SetRequest(method)
    return xfer.AsyncPostFromString(StrOrEmpty(opts.body))
end function

function HttpIsSuccess(code as Integer) as Boolean
    return code >= 200 and code < 300
end function

function HttpErrorText(res as Object) as String
    if res.code = 0 then return "No response (timed out)"
    if res.code < 0 then
        if res.reason <> "" then return res.reason
        return "Network error " + res.code.ToStr()
    end if
    return "HTTP " + res.code.ToStr()
end function
