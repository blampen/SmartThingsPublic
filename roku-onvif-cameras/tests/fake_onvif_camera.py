#!/usr/bin/env python3
"""A simulated ONVIF camera for developing the Roku channel without hardware.

Implements WS-Discovery (UDP 3702), the Device and Media (ver10) calls the
channel uses, WS-Security UsernameToken digest checking against the camera's
own (optionally skewed) clock, and a JPEG snapshot endpoint protected by HTTP
Basic or Digest auth. GetStreamUri returns whatever RTSP URL you pass with
--rtsp-url, e.g. a MediaMTX path fed by an ffmpeg test pattern.

    python3 fake_onvif_camera.py --host 192.168.1.50 --rtsp-url rtsp://192.168.1.50:8554/fakecam
"""

import argparse
import base64
import hashlib
import io
import os
import socket
import struct
import threading
import time
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NS = {
    "s": "http://www.w3.org/2003/05/soap-envelope",
    "wsse": "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd",
    "wsu": "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd",
    "tds": "http://www.onvif.org/ver10/device/wsdl",
    "trt": "http://www.onvif.org/ver10/media/wsdl",
    "tt": "http://www.onvif.org/ver10/schema",
}
ENVELOPE = (
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<SOAP-ENV:Envelope xmlns:SOAP-ENV="{s}" xmlns:tds="{tds}" xmlns:trt="{trt}" xmlns:tt="{tt}"'
    ' xmlns:ter="http://www.onvif.org/ver10/error">'
    "<SOAP-ENV:Body>{{body}}</SOAP-ENV:Body></SOAP-ENV:Envelope>"
).format(**NS)

PROFILES = [
    # token, name, encoding, width, height (deliberately not in size order)
    ("Profile_2", "subStream", "H264", 640, 360),
    ("Profile_1", "mainStream", "H264", 1280, 720),
    ("Profile_3", "mjpegStream", "JPEG", 1920, 1080),
]


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default="127.0.0.1", help="IP the camera is reachable on")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--advertise-host", help="IP to put in returned URLs (simulates a camera reporting a stale address)")
    p.add_argument("--user", default="admin")
    p.add_argument("--password", default="secret")
    p.add_argument("--clock-skew", type=int, default=0, help="seconds the camera clock is ahead of real time")
    p.add_argument("--rtsp-url", default="rtsp://{host}:8554/fakecam", help="URL returned by GetStreamUri")
    p.add_argument("--snapshot-auth", choices=["basic", "digest", "none"], default="digest")
    p.add_argument("--no-onvif-snapshot", action="store_true", help="GetSnapshotUri is not supported (like many cameras)")
    p.add_argument("--vendor-path", help="also serve snapshots at this path, e.g. /ISAPI/Streaming/channels/101/picture")
    p.add_argument("--name", default="Fake Camera")
    p.add_argument("--no-discovery", action="store_true")
    return p.parse_args()


ARGS = parse_args()
ADVERTISED = ARGS.advertise_host or ARGS.host
ENDPOINT_ID = "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_DNS, "%s:%d" % (ARGS.host, ARGS.port)))


def camera_now():
    return datetime.now(timezone.utc) + timedelta(seconds=ARGS.clock_skew)


def base_url():
    return "http://%s:%d" % (ADVERTISED, ARGS.port)


# ------------------------------------------------------------------ SOAP

def fault(code, reason, status=400):
    body = (
        "<SOAP-ENV:Fault><SOAP-ENV:Code><SOAP-ENV:Value>SOAP-ENV:Sender</SOAP-ENV:Value>"
        "<SOAP-ENV:Subcode><SOAP-ENV:Value>%s</SOAP-ENV:Value></SOAP-ENV:Subcode></SOAP-ENV:Code>"
        '<SOAP-ENV:Reason><SOAP-ENV:Text xml:lang="en">%s</SOAP-ENV:Text></SOAP-ENV:Reason></SOAP-ENV:Fault>'
    ) % (code, reason)
    return status, ENVELOPE.format(body=body)


def check_wsse(envelope):
    """Returns None when the UsernameToken is valid, else an error string."""
    token = envelope.find(".//wsse:UsernameToken", NS)
    if token is None:
        return "missing UsernameToken"
    user = token.findtext("wsse:Username", "", NS)
    password = token.find("wsse:Password", NS)
    nonce_b64 = token.findtext("wsse:Nonce", "", NS)
    created = token.findtext("wsu:Created", "", NS)
    if user != ARGS.user or password is None:
        return "unknown user %r" % user
    try:
        stamp = datetime.strptime(created.rstrip("Z").split(".")[0], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return "bad Created %r" % created
    skew = abs((stamp - camera_now()).total_seconds())
    if skew > 10:
        return "Created is %ds away from camera clock" % skew
    expected = base64.b64encode(hashlib.sha1(base64.b64decode(nonce_b64) + created.encode() + ARGS.password.encode()).digest()).decode()
    if password.text != expected:
        return "digest mismatch"
    return None


def op_system_date_and_time(_):
    now = camera_now()
    return (
        "<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime>"
        "<tt:DateTimeType>NTP</tt:DateTimeType><tt:DaylightSavings>false</tt:DaylightSavings>"
        "<tt:TimeZone><tt:TZ>UTC0</tt:TZ></tt:TimeZone>"
        "<tt:UTCDateTime><tt:Time><tt:Hour>%d</tt:Hour><tt:Minute>%d</tt:Minute><tt:Second>%d</tt:Second></tt:Time>"
        "<tt:Date><tt:Year>%d</tt:Year><tt:Month>%d</tt:Month><tt:Day>%d</tt:Day></tt:Date></tt:UTCDateTime>"
        "</tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>"
    ) % (now.hour, now.minute, now.second, now.year, now.month, now.day)


def op_capabilities(_):
    return (
        "<tds:GetCapabilitiesResponse><tds:Capabilities>"
        "<tt:Analytics><tt:XAddr>%(b)s/onvif/analytics</tt:XAddr></tt:Analytics>"
        "<tt:Device><tt:XAddr>%(b)s/onvif/device_service</tt:XAddr></tt:Device>"
        "<tt:Media><tt:XAddr>%(b)s/onvif/media_service</tt:XAddr>"
        "<tt:StreamingCapabilities><tt:RTP_RTSP_TCP>true</tt:RTP_RTSP_TCP></tt:StreamingCapabilities></tt:Media>"
        "</tds:Capabilities></tds:GetCapabilitiesResponse>"
    ) % {"b": base_url()}


def op_device_information(_):
    return (
        "<tds:GetDeviceInformationResponse><tds:Manufacturer>FakeCam</tds:Manufacturer>"
        "<tds:Model>FC-1000</tds:Model><tds:FirmwareVersion>1.0.0</tds:FirmwareVersion>"
        "<tds:SerialNumber>0001</tds:SerialNumber><tds:HardwareId>1</tds:HardwareId>"
        "</tds:GetDeviceInformationResponse>"
    )


def op_profiles(_):
    parts = []
    for token, name, encoding, width, height in PROFILES:
        parts.append(
            '<trt:Profiles token="%s" fixed="true"><tt:Name>%s</tt:Name>'
            '<tt:VideoSourceConfiguration token="VSC"><tt:Name>VideoSource</tt:Name><tt:UseCount>3</tt:UseCount>'
            '<tt:SourceToken>VS</tt:SourceToken><tt:Bounds x="0" y="0" width="1920" height="1080"/></tt:VideoSourceConfiguration>'
            '<tt:VideoEncoderConfiguration token="VEC_%s"><tt:Name>Encoder %s</tt:Name><tt:UseCount>1</tt:UseCount>'
            "<tt:Encoding>%s</tt:Encoding><tt:Resolution><tt:Width>%d</tt:Width><tt:Height>%d</tt:Height></tt:Resolution>"
            "<tt:Quality>5</tt:Quality><tt:RateControl><tt:FrameRateLimit>15</tt:FrameRateLimit>"
            "<tt:EncodingInterval>1</tt:EncodingInterval><tt:BitrateLimit>2048</tt:BitrateLimit></tt:RateControl>"
            "</tt:VideoEncoderConfiguration></trt:Profiles>" % (token, name, token, token, encoding, width, height)
        )
    # An audio-only profile, which the channel must skip.
    parts.append('<trt:Profiles token="Audio_1" fixed="false"><tt:Name>audioOnly</tt:Name></trt:Profiles>')
    return "<trt:GetProfilesResponse>%s</trt:GetProfilesResponse>" % "".join(parts)


def profile_token(envelope):
    return envelope.findtext(".//trt:ProfileToken", "", NS)


def op_stream_uri(envelope):
    url = ARGS.rtsp_url.format(host=ADVERTISED)
    token = profile_token(envelope)
    return (
        "<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>%s?profile=%s&amp;x=1</tt:Uri>"
        "<tt:InvalidAfterConnect>false</tt:InvalidAfterConnect><tt:InvalidAfterReboot>false</tt:InvalidAfterReboot>"
        "<tt:Timeout>PT0S</tt:Timeout></trt:MediaUri></trt:GetStreamUriResponse>"
    ) % (url, token)


def op_snapshot_uri(envelope):
    if ARGS.no_onvif_snapshot:
        return None
    return (
        "<trt:GetSnapshotUriResponse><trt:MediaUri><tt:Uri>%s/snapshot.jpg?profile=%s</tt:Uri>"
        "<tt:InvalidAfterConnect>false</tt:InvalidAfterConnect><tt:InvalidAfterReboot>false</tt:InvalidAfterReboot>"
        "<tt:Timeout>PT0S</tt:Timeout></trt:MediaUri></trt:GetSnapshotUriResponse>"
    ) % (base_url(), profile_token(envelope))


OPERATIONS = {
    "GetSystemDateAndTime": (op_system_date_and_time, False),
    "GetCapabilities": (op_capabilities, True),
    "GetDeviceInformation": (op_device_information, True),
    "GetProfiles": (op_profiles, True),
    "GetStreamUri": (op_stream_uri, True),
    "GetSnapshotUri": (op_snapshot_uri, True),
}


def handle_soap(raw):
    try:
        envelope = ET.fromstring(raw)
    except ET.ParseError as e:
        return fault("ter:WellFormed", "XML parse error: %s" % e)
    body = envelope.find("s:Body", NS)
    if body is None or len(body) == 0:
        return fault("ter:WellFormed", "missing Body")
    op = body[0].tag.split("}")[-1]
    if op not in OPERATIONS:
        return fault("ter:ActionNotSupported", "%s not supported" % op)
    handler, needs_auth = OPERATIONS[op]
    if needs_auth:
        problem = check_wsse(envelope)
        if problem:
            log("auth rejected for %s: %s" % (op, problem))
            return fault("ter:NotAuthorized", "Sender not Authorized")
    body = handler(envelope)
    if body is None:
        return fault("ter:ActionNotSupported", "%s not supported" % op)
    return 200, ENVELOPE.format(body=body)


# ------------------------------------------------------------------ snapshots

def snapshot_jpeg(profile):
    size = {t: (w, h) for t, _, _, w, h in PROFILES}.get(profile, (640, 360))
    try:
        from PIL import Image, ImageDraw

        img = Image.new("RGB", size, (20, 60, 110))
        draw = ImageDraw.Draw(img)
        stamp = datetime.now().strftime("%H:%M:%S.%f")[:-3]
        draw.rectangle([0, 0, size[0], 40], fill=(0, 0, 0))
        draw.text((10, 12), "%s  %s  %dx%d" % (ARGS.name, stamp, size[0], size[1]), fill=(255, 255, 255))
        offset = int(time.time() * 80) % size[0]
        draw.rectangle([offset, size[1] // 2 - 30, offset + 60, size[1] // 2 + 30], fill=(240, 180, 40))
        out = io.BytesIO()
        img.save(out, "JPEG", quality=80)
        return out.getvalue()
    except ImportError:
        # Smallest valid JPEG (1x1 grey) when Pillow is missing.
        return base64.b64decode(
            "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////"
            "////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="
        )


DIGEST_REALM = "FakeCam"
DIGEST_NONCE = uuid.uuid4().hex


def check_http_auth(header):
    if ARGS.snapshot_auth == "none":
        return True
    if not header:
        return False
    scheme, _, value = header.partition(" ")
    if ARGS.snapshot_auth == "basic" and scheme.lower() == "basic":
        return base64.b64decode(value).decode() == "%s:%s" % (ARGS.user, ARGS.password)
    if ARGS.snapshot_auth == "digest" and scheme.lower() == "digest":
        fields = {}
        for item in value.split(","):
            k, _, v = item.strip().partition("=")
            fields[k] = v.strip('"')
        ha1 = hashlib.md5(("%s:%s:%s" % (ARGS.user, DIGEST_REALM, ARGS.password)).encode()).hexdigest()
        ha2 = hashlib.md5(("GET:%s" % fields.get("uri", "")).encode()).hexdigest()
        if fields.get("qop"):
            expected = hashlib.md5(":".join([ha1, fields.get("nonce", ""), fields.get("nc", ""), fields.get("cnonce", ""), fields["qop"], ha2]).encode()).hexdigest()
        else:
            expected = hashlib.md5(("%s:%s:%s" % (ha1, fields.get("nonce", ""), ha2)).encode()).hexdigest()
        return fields.get("username") == ARGS.user and fields.get("response") == expected
    return False


# ------------------------------------------------------------------ HTTP

def log(message):
    print("[fake-onvif] %s" % message, flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        log("%s %s" % (self.address_string(), fmt % args))

    def send(self, status, body, content_type, extra=None):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if not self.path.startswith("/onvif/"):
            return self.send(404, "not found", "text/plain")
        status, body = handle_soap(raw)
        self.send(status, body, "application/soap+xml; charset=utf-8")

    def do_GET(self):
        path = self.path.split("?")[0]
        if path != "/snapshot.jpg" and path != ARGS.vendor_path:
            return self.send(404, "not found", "text/plain")
        if not check_http_auth(self.headers.get("Authorization")):
            if ARGS.snapshot_auth == "digest":
                challenge = 'Digest realm="%s", qop="auth", nonce="%s", algorithm=MD5' % (DIGEST_REALM, DIGEST_NONCE)
            else:
                challenge = 'Basic realm="%s"' % DIGEST_REALM
            return self.send(401, "unauthorized", "text/plain", {"WWW-Authenticate": challenge})
        profile = self.path.partition("profile=")[2].split("&")[0]
        self.send(200, snapshot_jpeg(profile), "image/jpeg", {"Cache-Control": "no-store"})


# ------------------------------------------------------------------ WS-Discovery

def probe_matches(relates_to):
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope"'
        ' xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"'
        ' xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"'
        ' xmlns:dn="http://www.onvif.org/ver10/network/wsdl">'
        "<SOAP-ENV:Header><wsa:MessageID>uuid:%s</wsa:MessageID><wsa:RelatesTo>%s</wsa:RelatesTo>"
        "<wsa:To>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:To>"
        "<wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</wsa:Action></SOAP-ENV:Header>"
        "<SOAP-ENV:Body><d:ProbeMatches><d:ProbeMatch>"
        "<wsa:EndpointReference><wsa:Address>%s</wsa:Address></wsa:EndpointReference>"
        "<d:Types>dn:NetworkVideoTransmitter</d:Types>"
        "<d:Scopes>onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/Profile/Streaming"
        " onvif://www.onvif.org/name/%s onvif://www.onvif.org/hardware/FC-1000 onvif://www.onvif.org/location/</d:Scopes>"
        "<d:XAddrs>http://[fe80::1]:%d/onvif/device_service http://%s:%d/onvif/device_service</d:XAddrs>"
        "<d:MetadataVersion>1</d:MetadataVersion></d:ProbeMatch></d:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>"
    ) % (uuid.uuid4(), relates_to, ENDPOINT_ID, ARGS.name.replace(" ", "%20"), ARGS.port, ARGS.host, ARGS.port)


def discovery_loop():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", 3702))
    mreq = struct.pack("4s4s", socket.inet_aton("239.255.255.250"), socket.inet_aton("0.0.0.0"))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    log("WS-Discovery listening on udp/3702")
    while True:
        data, sender = sock.recvfrom(65535)
        try:
            msg = ET.fromstring(data)
        except ET.ParseError:
            continue
        if not any(el.tag.endswith("}Probe") for el in msg.iter()):
            continue
        types = "".join(el.text or "" for el in msg.iter() if el.tag.endswith("}Types"))
        if types and "NetworkVideoTransmitter" not in types and "Device" not in types:
            continue
        message_id = "".join(el.text or "" for el in msg.iter() if el.tag.endswith("}MessageID"))
        sock.sendto(probe_matches(message_id).encode(), sender)
        log("answered probe from %s:%d" % sender)


def main():
    if not ARGS.no_discovery:
        threading.Thread(target=discovery_loop, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", ARGS.port), Handler)
    log("device service at http://%s:%d/onvif/device_service (user %r, clock skew %+ds, snapshot auth %s)"
        % (ARGS.host, ARGS.port, ARGS.user, ARGS.clock_skew, ARGS.snapshot_auth))
    if os.environ.get("FAKE_ONVIF_READY_FILE"):
        open(os.environ["FAKE_ONVIF_READY_FILE"], "w").close()
    server.serve_forever()


if __name__ == "__main__":
    main()
