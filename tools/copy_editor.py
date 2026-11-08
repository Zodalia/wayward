#!/usr/bin/env python3
"""A local page for a pass over every player-facing string, with the code
around each one, that saves edits straight back into the Lua.

    python -I tools/copy_editor.py            # then open http://127.0.0.1:8765
    python -I tools/copy_editor.py --open     # opens the browser for you
    python -I tools/copy_editor.py --port 9000

It finds strings the same way tools/extract_copy.py does (the TOC's files and
Notes line, the same filter for what counts as copy) but with a real Lua
scanner, so it knows the exact line and column of each literal. Saving
rewrites only the text between the quotes, checks the old text is still there
first (an edit to a line that changed since the page loaded is refused, not
guessed at), keeps the file's line endings, and regenerates docs/copy.md.

What you mark as reviewed lives in .copy-review.json at the repository root
(git-ignored), keyed by file and text, so it survives line moves and restarts.
Standard library only; it listens on 127.0.0.1.
"""
import argparse, io, json, os, re, subprocess, sys, threading, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # no tools/__pycache__ from importing extract_copy
sys.path.insert(0, HERE)
import extract_copy  # noqa: E402  (is_copy, files, main)

ROOT = os.path.dirname(HERE)
ADDON = os.path.join(ROOT, "Wayward")
TOC = os.path.join(ADDON, "Wayward.toc")
DESIGN = os.path.join(ROOT, "docs", "DESIGN.md")
REVIEW = os.path.join(ROOT, ".copy-review.json")
PAGE = os.path.join(HERE, "copy_editor.html")
LOCK = threading.Lock()

LONG_OPEN = re.compile(r"\[(=*)\[")
FUNC = re.compile(r"^\s*(?:local\s+)?function\s+([\w.:]+)\s*\(|^\s*(?:local\s+)?([\w.:\[\]\"']+)\s*=\s*function\s*\(")


# ---------------------------------------------------------------- reading

def read(path):
    with io.open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write(path, text):
    with io.open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def scan(text):
    """Yield (line, col, quote, raw) for each quoted string literal: col is the
    0-based column of the first character inside the quotes, raw is the text
    exactly as written (escapes and all). Skips comments and long strings."""
    i, n, line, start = 0, len(text), 1, 0

    def skip_long(i, m):
        nonlocal line, start
        close = "]" + m.group(1) + "]"
        j = text.find(close, m.end())
        j = n if j < 0 else j + len(close)
        for k in range(i, j):
            if text[k] == "\n":
                line, start = line + 1, k + 1
        return j

    while i < n:
        c = text[i]
        if c == "\n":
            line, start, i = line + 1, i + 1, i + 1
        elif c == "-" and text.startswith("--", i):
            m = LONG_OPEN.match(text, i + 2)
            if m:
                i = skip_long(i, m)
            else:
                j = text.find("\n", i)
                i = n if j < 0 else j
        elif c == "[" and LONG_OPEN.match(text, i):
            i = skip_long(i, LONG_OPEN.match(text, i))
        elif c in "\"'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            yield line, i + 1 - start, c, text[i + 1:j]
            i = j + 1
        else:
            i += 1


def kind_of(before, raw):
    """A rough hint at where a string shows up, from the code just before it
    (this line up to the string, plus the two lines above). Only a filter aid."""
    last = before.rsplit("\n", 1)[-1]
    if raw.startswith("/ww") or raw.startswith("/way") or "RegisterCommand" in last:
        return "Slash command"
    if re.search(r"\b(note|debug|Debug|dprint|trace)\s*\(", last) or "/ww debug" in before:
        return "Debug"
    if re.search(r"Tooltip|AddLine|AddDoubleLine|\btip\b|tooltip|explain\(|squareButton\(", before):
        return "Tooltip"
    if re.search(r"\bns\.print\(|\bprint\(|\bSay\(|ChatFrame|Announce", before):
        return "Chat"
    if re.search(r"SetText|SetFormattedText|\b(text|label|title|subtitle|header|desc|hint|sub|why|lead|zone)\s*=",
                 before):
        return "Label"
    return "Other"


def entries_for(rel, text):
    lines = text.split("\n")
    funcs = []
    for n, l in enumerate(lines, 1):
        m = FUNC.match(l)
        if m:
            funcs.append((n, m.group(1) or m.group(2)))
    out, fi, func = [], 0, None
    for line, col, quote, raw in scan(text):
        if not extract_copy.is_copy(raw):
            continue
        while fi < len(funcs) and funcs[fi][0] <= line:
            func = funcs[fi][1]
            fi += 1
        before = "\n".join(lines[max(0, line - 3):line - 1] + [lines[line - 1][:col]])
        out.append({"id": "%s:%d:%d" % (rel, line, col), "file": rel, "line": line, "col": col,
                    "quote": quote, "raw": raw, "func": func, "kind": kind_of(before, raw)})
    return out


def toc_entry(text):
    for n, l in enumerate(text.split("\n"), 1):
        if l.startswith("## Notes:"):
            col = len("## Notes:")
            while col < len(l) and l[col] == " ":
                col += 1
            return {"id": "Wayward.toc:%d:%d" % (n, col), "file": "Wayward.toc", "line": n, "col": col,
                    "quote": None, "raw": l.rstrip("\r")[col:], "func": None, "kind": "Addon list"}
    return None


def lua_files():
    _, files = extract_copy.files()
    return [f for f in files if not (f.startswith("Data/") and f != "Data/Seed.lua")]


def vocabulary():
    """The Vocabulary table in docs/DESIGN.md: [{term, avoid: [...]}]."""
    out, inside = [], False
    for l in read(DESIGN).splitlines():
        if l.startswith("## Vocabulary"):
            inside = True
        elif inside and l.startswith("## "):
            break
        elif inside and l.startswith("| **"):
            cells = [c.strip() for c in l.strip("|").split("|")]
            term = cells[0].strip("* ")
            avoid = [re.sub(r"\s*\(.*\)", "", a).strip() for a in cells[-1].split(",")]
            out.append({"term": term, "avoid": [a for a in avoid if a]})
    return out


def load_review():
    try:
        return json.loads(read(REVIEW))
    except (OSError, ValueError):
        return {}


def review_key(file, raw):
    return file + "\u0000" + raw


def snapshot():
    entries, sources = [], {}
    text = read(TOC)
    t = toc_entry(text)
    if t:
        entries.append(t)
        sources["Wayward.toc"] = [l.rstrip("\r") for l in text.split("\n")]
    for rel in lua_files():
        text = read(os.path.join(ADDON, rel))
        found = entries_for(rel, text)
        if found:
            entries += found
            sources[rel] = [l.rstrip("\r") for l in text.split("\n")]
    review = load_review()
    for e in entries:
        e["reviewed"] = review_key(e["file"], e["raw"]) in review
    return {"entries": entries, "sources": sources, "vocab": vocabulary(), "addon": ADDON.replace("\\", "/")}


# ---------------------------------------------------------------- saving

def encode(new, quote):
    """Make what was typed safe to put back between the quotes: newlines become
    \\n and a bare quote of the same kind is escaped. Everything else (|cff
    codes, %s, existing escapes) goes in exactly as typed."""
    new = new.replace("\r\n", "\n").replace("\n", "\\n")
    if quote is None:
        return new
    out, bs = [], 0
    for ch in new:
        if ch == quote and bs % 2 == 0:
            out.append("\\")
        out.append(ch)
        bs = bs + 1 if ch == "\\" else 0
    if bs % 2 == 1:
        raise ValueError("ends with a lone backslash, which would swallow the closing quote")
    return "".join(out)


def save(edits):
    """edits: [{id, file, line, col, quote, old, new}]. All-or-nothing per file."""
    by_file, results = {}, {"saved": [], "refused": []}
    for e in edits:
        by_file.setdefault(e["file"], []).append(e)
    review = load_review()
    allowed = set(lua_files()) | {"Wayward.toc"}
    for rel, es in by_file.items():
        path = TOC if rel == "Wayward.toc" else os.path.join(ADDON, rel)
        if rel not in allowed or not os.path.exists(path):
            results["refused"] += [{"id": e.get("id"), "why": "not a Wayward file"} for e in es]
            continue
        lines = read(path).split("\n")
        problems, applied = [], []
        # Right to left within a line, so earlier columns stay put.
        for e in sorted(es, key=lambda e: (e["line"], -e["col"])):
            try:
                new = encode(e["new"], e["quote"])
            except ValueError as err:
                problems.append({"id": e["id"], "why": str(err)})
                continue
            i, col, old = e["line"] - 1, e["col"], e["old"]
            l = lines[i] if 0 <= i < len(lines) else ""
            cr = "\r" if l.endswith("\r") else ""
            body = l[:-1] if cr else l
            end = col + len(old)
            if e["quote"] is None:
                ok = body[col:] == old
            else:
                ok = body[col:end] == old and body[end:end + 1] == e["quote"]
            if not ok:
                problems.append({"id": e["id"], "why": "the line has changed since the page loaded; reload"})
                continue
            lines[i] = body[:col] + new + body[end:] + cr
            applied.append((e, new))
        if problems:  # leave the file alone rather than half-apply it
            results["refused"] += problems + [{"id": e["id"], "why": "another edit in this file was refused"}
                                              for e, _ in applied]
            continue
        write(path, "\n".join(lines))
        for e, new in applied:
            review.pop(review_key(rel, e["old"]), None)
            review[review_key(rel, new)] = True
            results["saved"].append(e["id"])
    if results["saved"]:
        write(REVIEW, json.dumps(review, indent=0, sort_keys=True))
        stdout = sys.stdout
        try:
            sys.stdout = io.StringIO()
            extract_copy.main()
            results["copy_md"] = True
        except Exception as err:  # the edit itself is already safe on disk
            results["copy_md"] = "docs/copy.md not regenerated: %s" % err
        finally:
            sys.stdout = stdout
    return results


def set_reviewed(items):
    review = load_review()
    for it in items:
        k = review_key(it["file"], it["raw"])
        if it.get("reviewed"):
            review[k] = True
        else:
            review.pop(k, None)
    write(REVIEW, json.dumps(review, indent=0, sort_keys=True))
    return {"ok": True}


def run(cmd, env=None):
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace",
                       env=dict(os.environ, **(env or {})), timeout=300)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def checks():
    out = []
    for label, cmd, env in [
        ("lua tests/wayward_smoke.lua", ["lua", "tests/wayward_smoke.lua"], None),
        ("WAYWARD_GAME=era lua tests/wayward_smoke.lua", ["lua", "tests/wayward_smoke.lua"], {"WAYWARD_GAME": "era"}),
        ("python3 -I tools/lua51.py tests/wayward_smoke.lua",
         [sys.executable, "-I", "tools/lua51.py", "tests/wayward_smoke.lua"], None),
    ]:
        try:
            code, text = run(cmd, env)
        except (OSError, subprocess.SubprocessError) as err:
            code, text = 1, str(err)
        tail = "\n".join(text.strip().splitlines()[-15:])
        out.append({"cmd": label, "ok": code == 0, "tail": tail})
    return {"checks": out}


def diff():
    try:
        _, text = run(["git", "diff", "--no-color", "-U1", "--", "Wayward"])
    except (OSError, subprocess.SubprocessError) as err:
        text = str(err)
    return {"diff": text}


# ---------------------------------------------------------------- server

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def json(self, obj, code=200):
        self.send(code, json.dumps(obj))

    def do_GET(self):
        path = self.path.split("?")[0]
        try:
            if path in ("/", "/index.html"):
                self.send(200, read(PAGE), "text/html; charset=utf-8")
            elif path == "/api/copy":
                with LOCK:
                    self.json(snapshot())
            elif path == "/api/diff":
                self.json(diff())
            else:
                self.json({"error": "not found"}, 404)
        except Exception as err:
            self.json({"error": str(err)}, 500)

    def do_POST(self):
        # Only the page itself may write: refuse cross-site posts.
        origin = self.headers.get("Origin")
        if origin and origin.split("://", 1)[-1] != self.headers.get("Host", ""):
            return self.json({"error": "cross-origin request refused"}, 403)
        if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
            return self.json({"error": "expected JSON"}, 415)
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            path = self.path.split("?")[0]
            with LOCK:
                if path == "/api/save":
                    self.json(save(body.get("edits", [])))
                elif path == "/api/review":
                    self.json(set_reviewed(body.get("items", [])))
                elif path == "/api/check":
                    self.json(checks())
                else:
                    self.json({"error": "not found"}, 404)
        except Exception as err:
            self.json({"error": str(err)}, 500)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--open", action="store_true", help="open the page in your browser")
    args = ap.parse_args()
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = "http://127.0.0.1:%d/" % args.port
    print("Wayward copy editor on %s (Ctrl+C to stop)" % url, flush=True)
    if args.open:
        webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
