#!/usr/bin/env python3
"""Fetch VTODOs from a CalDAV server and print them as JSON.

Usage: fetch_tasks.py SERVER_URL USERNAME PASSWORD CALENDAR_NAME [CALENDAR_URL]

The calendar is located in this order:
  1. CALENDAR_URL, if given (absolute, or relative to SERVER_URL);
  2. Nextcloud's layout:  SERVER_URL/remote.php/dav/calendars/USERNAME/
  3. standard CalDAV discovery (RFC 4791 / RFC 6764): current-user-principal
     -> calendar-home-set -> the calendars that support VTODO.

Output (always exits 0):
  {"ok": true, "url": "<calendar url>", "tasks": [...]}
  {"ok": false, "message": "..."}
"""
import base64
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

DAV = "{DAV:}"
CALDAV = "{urn:ietf:params:xml:ns:caldav}"
CS = "{http://calendarserver.org/ns/}"
TIMEOUT = 30
MAX_REDIRECTS = 5

LIST_CALENDARS = (
    '<?xml version="1.0"?>'
    '<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop>'
    "<d:displayname/><d:resourcetype/><c:supported-calendar-component-set/>"
    "</d:prop></d:propfind>"
)
FIND_HOME = (
    '<?xml version="1.0"?>'
    '<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop>'
    "<d:current-user-principal/><c:calendar-home-set/>"
    "</d:prop></d:propfind>"
)

PROP_CTAG = (
    '<?xml version="1.0"?>'
    '<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/"><d:prop>'
    "<cs:getctag/><d:sync-token/>"
    "</d:prop></d:propfind>"
)

REPORT_TODOS = (
    '<?xml version="1.0" encoding="utf-8"?>'
    '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
    "<d:prop><d:getetag/><c:calendar-data/></d:prop>"
    '<c:filter><c:comp-filter name="VCALENDAR">'
    '<c:comp-filter name="VTODO"/></c:comp-filter></c:filter>'
    "</c:calendar-query>"
)


class Fail(Exception):
    """A problem worth showing to the user."""


class BadXML(Fail):
    """The server answered, but not with XML (e.g. an HTML page)."""


def die(msg):
    print(json.dumps({"ok": False, "message": msg}))
    sys.exit(0)


# --------------------------------------------------------------------- HTTP

class Client:
    def __init__(self, server, user, password):
        parts = urllib.parse.urlsplit(server)
        if parts.scheme not in ("http", "https") or not parts.netloc:
            raise Fail("Server URL must start with http:// or https://")
        self.server = server.rstrip("/")
        self.scheme, self.netloc = parts.scheme, parts.netloc
        self.origin = f"{parts.scheme}://{parts.netloc}"
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        self.auth = "Basic " + token

    def _check(self, url):
        # The credentials are only ever sent to the configured host, over the
        # configured scheme (no downgrade from https to http).
        p = urllib.parse.urlsplit(url)
        if p.netloc != self.netloc or (self.scheme == "https" and p.scheme != "https"):
            raise Fail(f"Refusing to send credentials to {p.scheme}://{p.netloc}")

    def request(self, method, url, body=None, depth=None):
        """Return (text, final_url). urllib does not follow redirects for
        PROPFIND/REPORT, so they are followed here. HTTPError is re-raised
        for the caller, except 401 which becomes a clear Fail."""
        for _ in range(MAX_REDIRECTS + 1):
            self._check(url)
            req = urllib.request.Request(
                url, data=body.encode() if body else None, method=method)
            req.add_header("Authorization", self.auth)
            if body:
                req.add_header("Content-Type", "application/xml; charset=utf-8")
            if depth is not None:
                req.add_header("Depth", depth)
            try:
                with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                    return resp.read().decode("utf-8", "replace"), url
            except urllib.error.HTTPError as e:
                location = e.headers.get("Location") if e.headers else None
                if e.code in (301, 302, 303, 307, 308) and location:
                    url = urllib.parse.urljoin(url, location)
                    continue
                if e.code == 401:
                    raise Fail("Authentication failed (HTTP 401): check the "
                               "username and app password")
                raise
            except urllib.error.URLError as e:
                raise Fail(f"Connection failed: {e.reason}")
            except OSError as e:
                raise Fail(f"Request failed: {e}")
        raise Fail("Too many redirects")


# ---------------------------------------------------------------------- XML

def parse_xml(text):
    try:
        return ET.fromstring(text)
    except ET.ParseError as e:
        raise BadXML(f"Invalid XML from server: {e}")


def ok_props(response):
    """The <prop> blocks of a <response> that the server answered with 200."""
    for ps in response.findall(DAV + "propstat"):
        status = ps.findtext(DAV + "status") or ""
        if status and " 200" not in status:
            continue
        prop = ps.find(DAV + "prop")
        if prop is not None:
            yield prop


def hrefs(root, base, wrapper):
    out = []
    for resp in root.iter(DAV + "response"):
        for prop in ok_props(resp):
            for el in prop.findall(wrapper + "/" + DAV + "href"):
                if el.text and el.text.strip():
                    out.append(urllib.parse.urljoin(base, el.text.strip()))
    return out


# ---------------------------------------------------------------- discovery

def list_calendars(client, home_url):
    text, final = client.request("PROPFIND", home_url, LIST_CALENDARS, depth="1")
    root = parse_xml(text)
    cals = []
    for resp in root.iter(DAV + "response"):
        href = (resp.findtext(DAV + "href") or "").strip()
        if not href:
            continue
        for prop in ok_props(resp):
            rtype = prop.find(DAV + "resourcetype")
            if rtype is None or rtype.find(CALDAV + "calendar") is None:
                continue
            comp_set = prop.find(CALDAV + "supported-calendar-component-set")
            comps = None if comp_set is None else {
                (c.get("name") or "").upper()
                for c in comp_set.findall(CALDAV + "comp")}
            cals.append({
                "url": urllib.parse.urljoin(final, href),
                "name": (prop.findtext(DAV + "displayname") or "").strip(),
                # servers that do not report the set are given the benefit of the doubt
                "todo": comps is None or "VTODO" in comps,
            })
            break
    return cals


def discover_homes(client):
    starts = []
    for u in (client.origin + "/.well-known/caldav", client.server + "/"):
        if u not in starts:
            starts.append(u)
    for start in starts:
        try:
            text, final = client.request("PROPFIND", start, FIND_HOME, depth="0")
            root = parse_xml(text)
        except (urllib.error.HTTPError, BadXML):
            continue
        homes = hrefs(root, final, CALDAV + "calendar-home-set")
        if homes:
            return homes
        for principal in hrefs(root, final, DAV + "current-user-principal"):
            try:
                text, final2 = client.request("PROPFIND", principal, FIND_HOME, depth="0")
                root2 = parse_xml(text)
            except (urllib.error.HTTPError, BadXML):
                continue
            homes = hrefs(root2, final2, CALDAV + "calendar-home-set")
            if homes:
                return homes
    return []


def find_calendars(client, user):
    # 1. Nextcloud's layout: one request, and it keeps existing setups unchanged.
    nc_home = f"{client.server}/remote.php/dav/calendars/{urllib.parse.quote(user, safe='@')}/"
    try:
        cals = list_calendars(client, nc_home)
        if cals:
            return cals
    except (urllib.error.HTTPError, BadXML):
        pass
    # 2. Standard discovery.
    cals, seen = [], set()
    for home in discover_homes(client):
        try:
            for c in list_calendars(client, home):
                if c["url"] not in seen:
                    seen.add(c["url"])
                    cals.append(c)
        except (urllib.error.HTTPError, BadXML):
            continue
    return cals


def norm(s):
    return re.sub(r"\W", "", s.lower())


def slug(url):
    return urllib.parse.unquote(url.rstrip("/").rsplit("/", 1)[-1])


def choose_calendar(cals, wanted):
    todo = [c for c in cals if c["todo"]]
    label = lambda c: c["name"] or slug(c["url"])
    if not todo:
        raise Fail("No calendar with task (VTODO) support found. "
                   "Set the Calendar URL in the plugin settings.")
    want = norm(wanted)
    keys = lambda c: {k for k in (norm(c["name"]), norm(slug(c["url"]))) if k}
    if want:
        for c in todo:
            if want in keys(c):
                return c
        for c in todo:
            if any(want in k or k in want for k in keys(c)):
                return c
        raise Fail(f"Calendar '{wanted}' not found. Available: "
                   + (", ".join(label(c) for c in todo) or "(none)"))
    if len(todo) == 1:
        return todo[0]
    raise Fail("Set the calendar name. Available: " + ", ".join(label(c) for c in todo))


# ------------------------------------------------------------------- VTODOs

def unfold(ics):
    # RFC 5545 line folding: continuation lines start with a space or tab
    return re.sub(r"\r?\n[ \t]", "", ics)


def ical_text(s):
    """Undo iCalendar TEXT escaping (\\, \\; \\\\ \\n)."""
    return re.sub(r"\\([nN,;\\])",
                  lambda m: "\n" if m.group(1) in "nN" else m.group(1), s)


def parse_vtodo(ics):
    """Properties of the first VTODO (top level only, not VALARM etc.) as
    {NAME: [value, ...]}."""
    props, stack, seen = {}, [], False
    for line in unfold(ics).split("\n"):
        line = line.rstrip("\r")
        if not line:
            continue
        upper = line.upper()
        if upper.startswith("BEGIN:"):
            stack.append(upper[6:].strip())
            if stack[-1] == "VTODO":
                seen = True
            continue
        if upper.startswith("END:"):
            if stack and stack[-1] == "VTODO" and seen:
                break
            if stack:
                stack.pop()
            continue
        if not stack or stack[-1] != "VTODO":
            continue
        m = re.match(r"([A-Za-z0-9-]+)[;:]", line)
        if m and ":" in line:
            props.setdefault(m.group(1).upper(), []).append(line.split(":", 1)[1])
    return props

def get_ctag(client, cal_url):
    """Cheap change marker for the calendar (ctag, else sync-token), or None.
    Any problem returns None, which just means 'do the full fetch'."""
    try:
        text, _ = client.request("PROPFIND", cal_url, PROP_CTAG, depth="0")
        root = parse_xml(text)
    except (urllib.error.HTTPError, Fail):
        return None
    for resp in root.iter(DAV + "response"):
        for prop in ok_props(resp):
            for tag in (CS + "getctag", DAV + "sync-token"):
                value = prop.findtext(tag)
                if value and value.strip():
                    return value.strip()
    return None

def fetch_tasks(client, cal_url):
    try:
        text, final = client.request("REPORT", cal_url, REPORT_TODOS, depth="1")
    except urllib.error.HTTPError as e:
        raise Fail(f"REPORT failed: HTTP {e.code}")
    root = parse_xml(text)
    tasks = []
    for resp in root.iter(DAV + "response"):
        href = (resp.findtext(DAV + "href") or "").strip()
        if not href:
            continue
        data, etag = None, None
        for prop in ok_props(resp):
            el = prop.find(CALDAV + "calendar-data")
            if el is not None and el.text:
                data = el.text
            tag = prop.findtext(DAV + "getetag")
            if tag and tag.strip():
                etag = tag.strip()
        if not data:
            continue
        p = parse_vtodo(data)
        first = lambda name: (p.get(name) or [None])[0]
        summary = ical_text(first("SUMMARY") or "").replace("\n", " ").strip()
        status = (first("STATUS") or "").strip().upper()
        tags = []
        for value in p.get("CATEGORIES", []):
            for part in re.split(r"(?<!\\),", value):
                part = ical_text(part).strip()
                if part and part not in tags:
                    tags.append(part)
        due = (first("DUE") or "").strip() or None
        tasks.append({
            "href": urllib.parse.urljoin(final, href),
            "etag": etag,
            "summary": summary or "(no summary)",
            "done": status in ("COMPLETED", "CANCELLED"),
            "tags": tags,
            "due": due,
        })
    tasks.sort(key=lambda t: (t["done"], t["summary"].lower()))
    return tasks


def main():
    args = sys.argv[1:]
    if len(args) < 4:
        die("usage: fetch_tasks.py SERVER USER PASSWORD CALENDAR [CALENDAR_URL] [PREV_CTAG]")
    server, user, password, calendar = (a.strip() if i != 2 else a
                                        for i, a in enumerate(args[:4]))
    override = args[4].strip() if len(args) > 4 else ""
    previous = args[5].strip() if len(args) > 5 else ""
    try:
        client = Client(server, user, password)
        if override:
            cal_url = urllib.parse.urljoin(client.server + "/", override)
        else:
            cal_url = choose_calendar(find_calendars(client, user), calendar)["url"]
        if not cal_url.endswith("/"):
            cal_url += "/"
        # Read the marker BEFORE fetching, so a change landing in between
        # is picked up by the next sync.
        ctag = get_ctag(client, cal_url)
        if ctag and ctag == previous:
            print(json.dumps({"ok": True, "url": cal_url, "ctag": ctag, "unchanged": True}))
            return
        tasks = fetch_tasks(client, cal_url)
    except Fail as e:
        die(str(e))
    except urllib.error.HTTPError as e:
        die(f"HTTP {e.code} from the server")
    except Exception as e:  # never leave the plugin without a JSON answer
        die(f"{type(e).__name__}: {e}")
    out = {"ok": True, "url": cal_url, "tasks": tasks}
    if ctag:
        out["ctag"] = ctag
    print(json.dumps(out))


if __name__ == "__main__":
    main()
