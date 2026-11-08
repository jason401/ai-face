"""Opt-in History replication. Cloud I/O runs in a disposable, timed subprocess.

Only the owning Mac publishes a device directory. A manifest is the commit record:
readers adopt a complete verified generation, retaining their previous cache otherwise.
No conversation text or hardware identifier is published.
"""
import datetime
import functools
import hashlib
import json
import platform
import re
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

from . import history, paths

_LOCK = threading.RLock()
_process = None
_running = False
_status = "off"
_last = 0
_identity = None
_wake = threading.Event()
CLOUD = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/AI Face/history/v1/devices"
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}\.jsonl$")
ID = re.compile(r"^[a-f0-9]{32}$")


def folder():
    return history.FOLDER.parent / "history-sync"


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        tmp.write_bytes(data)
        tmp.replace(path)
    finally:
        tmp.unlink(missing_ok=True)


def save_json(path, value):
    atomic(path, json.dumps(value, ensure_ascii=False, allow_nan=False).encode())


def hardware():
    try:
        result = subprocess.run(
            ["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
            capture_output=True, timeout=5, check=True)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ValueError("Cannot identify this Mac") from exc
    match = re.search(rb'"IOPlatformUUID"\s*=\s*"([^"]+)"', result.stdout)
    if not match:
        raise ValueError("Cannot identify this Mac")
    return hashlib.sha256(match[1]).hexdigest()


def initialize():
    """Runs before any new record. A copied identity never becomes a second writer."""
    global _identity
    with _LOCK:
        hw = hardware()
        state = read_json(folder() / "identity.json")
        if not state or state.get("hardware") != hw:
            state = dict(id=uuid.uuid4().hex, hardware=hw, name=platform.node(), imported=False)
            # Copied records keep their original device fields. Disable inherited opt-in.
            save_json(folder() / "settings.json", dict(enabled=False))
        if not ID.fullmatch(state.get("id", "")):
            raise ValueError("Invalid History identity")
        state["name"] = platform.node()
        save_json(folder() / "identity.json", state)
        _identity = state
        return dict(state)


def device_id():
    return _identity["id"] if _identity else None


def enabled():
    return read_json(folder() / "settings.json", {}).get("enabled") is True


@functools.lru_cache(maxsize=1)
def _cached_generation(path, stamp):
    # Reuse the decoded local snapshot between the settings window's polls.
    return read_json(path, {})


def cached():
    path = folder() / "cache.json"
    try:
        stat = path.stat()
    except FileNotFoundError:
        return {}
    return _cached_generation(path, (stat.st_ino, stat.st_mtime_ns, stat.st_size))


def configure(on, import_existing=True):
    global _status
    if type(on) is not bool or type(import_existing) is not bool:
        raise ValueError("Invalid History sync setting")
    with _LOCK:
        if on:
            if _identity is None:
                initialize()
            if not _identity.get("imported"):
                # Explicit choice for pre-ownership records, including pre-feature migrations.
                history.assign_legacy(device_id() if import_existing else "")
                _identity["imported"] = True
                save_json(folder() / "identity.json", _identity)
        save_json(folder() / "settings.json", dict(enabled=on))
        if not on and _process is not None:
            _process.terminate()
        _status = "waiting" if on else "off"
    _wake.set()


def status():
    with _LOCK:
        on = enabled()
        devices = [dict(id=device_id() or "local", name=platform.node())]
        if on:
            devices.extend(dict(id=k, name=v["name"]) for k, v in cached().items()
                           if k != device_id())
        return dict(enabled=on, state=_status if on else "off", last=_last,
                    imported=bool(_identity and _identity.get("imported")),
                    devices=devices)


def request():
    _wake.set()


def snapshot():
    """Local file snapshot under the same lock as append, migration and deletion."""
    with history.LOCK:
        files = {}
        for path in history.FOLDER.glob("*.jsonl"):
            if DAY.fullmatch(path.name):
                rows = [e for e in history.read_events(path) if e.get("device") == device_id()]
                if rows:
                    files[path.name] = "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in rows)
        return files


def synchronize():
    global _process, _running, _status, _last
    with _LOCK:
        if not enabled() or _running:
            return
        _running = True
        _status = "syncing"
    try:
        history.prune()
        # No Cloud reads in the server process, including directory existence checks.
        payload = dict(cloud=str(CLOUD), id=device_id(), name=platform.node(),
                       files=snapshot(), cache=cached())
        with _LOCK:
            if not enabled():
                return
            _process = subprocess.Popen([sys.executable, "-B", "-m", "aiface.history_sync", "--worker"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE,
                                        cwd=str(Path(__file__).resolve().parents[1]))
            child = _process
        try:
            output, _ = child.communicate(json.dumps(payload).encode(), timeout=30)
        except subprocess.TimeoutExpired:
            child.kill()
            child.communicate()
            raise TimeoutError("iCloud download pending")
        if child.returncode:
            raise OSError("iCloud unavailable")
        result = json.loads(output)
        with _LOCK:
            if enabled():
                save_json(folder() / "cache.json", result["cache"])
                _last = time.time()
                _status = "waiting" if result["pending"] else "ready"
    except (OSError, ValueError, TimeoutError):
        with _LOCK:
            _status = "waiting" if enabled() else "off"
    finally:
        with _LOCK:
            _process = None
            _running = False


def watch(stop):
    while not stop.is_set():
        try:
            synchronize()
        except (OSError, ValueError):
            pass
        _wake.wait(30)
        _wake.clear()


def shutdown():
    with _LOCK:
        if _process is not None:
            _process.terminate()
    _wake.set()


def aggregate(selection="all", kind=None, day=None):
    """None selects history.period's local path when OFF; no cache or log scan."""
    if not enabled():
        return None
    start, end = history.period_range(kind, day) if kind is not None else (None, None)
    if end is not None:
        end = min(end, datetime.date.today())
    with history.LOCK:
        if start is None:
            local = [e for p in history.FOLDER.glob("*.jsonl") if DAY.fullmatch(p.name)
                     for e in history.read_events(p)]
        else:
            local = []
            date = start
            while date <= end:
                local.extend(history.events(date.isoformat()))
                date += datetime.timedelta(days=1)
    mine = device_id()
    if selection == "local":
        by_device = {mine: [e for e in local if e.get("device") == mine]}
    else:
        by_device = {}
        for e in local:
            owner = e.get("device")
            if owner:
                by_device.setdefault(owner, []).append(e)
        # Cache is local disk only, and is read outside the recording lock.
        for key, value in cached().items():
            if key != mine:
                by_device[key] = value["events"]
        if selection != "all":
            by_device = {selection: by_device.get(selection, [])}
    cutoff = time.time() - history.KEEP_DAYS * 86400
    return sorted((e for rows in by_device.values() for e in rows
                   if e["t"] >= cutoff and
                   (start is None or start.isoformat() <= history._day(e["t"]) <= end.isoformat())),
                  key=lambda e: e["t"])


def manifest(raw, owner):
    if (not isinstance(raw, dict) or raw.get("version") != 1 or raw.get("id") != owner
            or type(raw.get("generation")) is not int or raw["generation"] < 1
            or not isinstance(raw.get("name"), str) or not isinstance(raw.get("files"), dict)):
        raise ValueError("Invalid History manifest")
    for name, checksum in raw["files"].items():
        if not DAY.fullmatch(name) or not isinstance(checksum, str) or not re.fullmatch("[a-f0-9]{64}", checksum):
            raise ValueError("Invalid History file")
    return raw


def download(items):
    """Ask the signed app to hydrate legacy .icloud placeholders as well as dataless files."""
    bundle = paths.app_bundle()
    if bundle is None or not items:
        return
    try:
        subprocess.run([str(bundle / "Contents/MacOS/AIFace"), "--history-download",
                        *map(str, items)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        pass  # Reads below decide whether the generation is actually available.


def replicate(payload):
    """Worker only. May block on iCloud; the parent kills the whole worker after 30s."""
    cloud = Path(payload["cloud"])
    # Never create a fake iCloud Drive tree when iCloud is disabled/unavailable.
    if not cloud.parents[3].is_dir():
        raise OSError("iCloud Drive is unavailable")
    owner = payload["id"]
    if not isinstance(owner, str) or not ID.fullmatch(owner):
        raise ValueError("Invalid device")
    own = cloud / owner
    download([own / "device.json"])
    previous = read_json(own / "device.json")
    if previous is not None:
        manifest(previous, owner)
    files = {name: value.encode() for name, value in payload["files"].items()}
    hashes = {name: hashlib.sha256(value).hexdigest() for name, value in files.items()}
    # Manifest equality does not prove the referenced bytes still exist.
    # Hydrate before checking; access errors/timeouts abort rather than overwrite.
    download([own / name for name in files])
    repaired = False
    for name, value in files.items():
        target = own / name
        try:
            actual = hashlib.sha256(target.read_bytes()).hexdigest()
        except FileNotFoundError:
            # A legacy placeholder is pending download, not a deleted file.
            if target.with_name("." + name + ".icloud").exists():
                raise TimeoutError("iCloud download pending")
            actual = None
        if actual != hashes[name]:
            atomic(target, value)
            repaired = True
    if repaired or not previous or previous["files"] != hashes or previous["name"] != payload["name"]:
        head = dict(version=1, id=owner, name=payload["name"],
                    generation=max(time.time_ns(), (previous["generation"] if previous else 0) + 1), files=hashes)
        save_json(own / "device.json", head)  # publish only after all files
        for path in own.glob("*.jsonl"):
            if DAY.fullmatch(path.name) and path.name not in files:
                path.unlink()
    cache = payload["cache"]
    pending = False
    seen = set()
    for peer in cloud.iterdir():
        if peer.name == owner or not ID.fullmatch(peer.name):
            continue
        seen.add(peer.name)
        try:
            download([peer / "device.json"])
            head = manifest(read_json(peer / "device.json"), peer.name)
            old = cache.get(peer.name)
            if old and head["generation"] < old["generation"]:
                raise ValueError("Stale manifest")
            if old and head["generation"] == old["generation"]:
                if head["files"] != old["files"]:
                    raise ValueError("Conflicting manifest")
                continue
            rows = []
            download([peer / name for name in head["files"]])
            for name, checksum in head["files"].items():
                data = (peer / name).read_bytes()
                if hashlib.sha256(data).hexdigest() != checksum:
                    raise ValueError("History file not downloaded yet")
                events = history.decode_events(data.decode())
                if (len(events) != len([line for line in data.decode().splitlines() if line.strip()])
                        or any(e.get("device") != peer.name for e in events)):
                    raise ValueError("Wrong History owner")
                rows.extend(events)
            # Commit the complete verified snapshot, including authoritative empty lists.
            cache[peer.name] = dict(name=head["name"], generation=head["generation"],
                                   files=head["files"], events=rows)
        except (OSError, ValueError, TypeError):
            pending = True
    pending = pending or bool(set(cache) - seen - {owner})
    return dict(cache=cache, pending=pending)


def probe():
    """Explicit developer CLI only; never called on startup or by an OFF sync."""
    import tempfile
    root = CLOUD.parents[3]
    if not root.is_dir():
        print(json.dumps(dict(available=False, reason="iCloud Drive is not enabled")))
        return
    with tempfile.TemporaryDirectory(prefix=".aiface-access-probe-", dir=root) as temporary:
        path = Path(temporary) / "probe"
        atomic(path, b"AI Face iCloud access probe")
        if path.read_bytes() != b"AI Face iCloud access probe":
            raise OSError("iCloud read/write verification failed")
    print(json.dumps(dict(available=True, read_write=True)))


if __name__ == "__main__":
    if sys.argv[1:] == ["--probe"]:
        probe()
        raise SystemExit(0)
    if sys.argv[1:] != ["--worker"]:
        raise SystemExit(2)
    try:
        print(json.dumps(replicate(json.load(sys.stdin)), allow_nan=False))
    except (OSError, ValueError, TypeError):
        raise SystemExit(1)
