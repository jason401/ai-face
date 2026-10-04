"""Expression log: every face change (when, who chose it, which mood), one JSON line per
change in a file per day, and summaries for the app's 기록 tab and the get_expression
MCP tool. Only the mood is kept, never anything from the conversation.
Python standard library only."""
import datetime
import json
import os
import time

from . import paths

FOLDER = paths.DATA / 'history'
OWNERS = ('claude', 'gpt', 'user')
KEEP_DAYS = 400


def _day(t):
    return datetime.date.fromtimestamp(t).isoformat()


def _file(day):
    return FOLDER / f'{day}.jsonl'


def record(owner, emotion, now=None):
    """Append one face change. Never raises: the log is a nice-to-have."""
    now = time.time() if now is None else now
    if owner not in OWNERS or not isinstance(emotion, str) or not emotion:
        return
    try:
        FOLDER.mkdir(parents=True, exist_ok=True)
        line = json.dumps(dict(t=round(now, 1), owner=owner, emotion=emotion), ensure_ascii=False)
        with open(_file(_day(now)), 'a') as f:
            f.write(line + '\n')
    except OSError:
        pass


def events(day):
    """[{t, owner, emotion}] of one day ('YYYY-MM-DD'), oldest first."""
    try:
        datetime.date.fromisoformat(day)
        lines = _file(day).read_text().splitlines()
    except (OSError, ValueError, TypeError):
        return []
    out = []
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if isinstance(e, dict) and e.get('owner') in OWNERS and isinstance(e.get('emotion'), str) \
                and isinstance(e.get('t'), (int, float)):
            out.append(e)
    return out


def recent(n=20, now=None):
    """The last n changes, newest first (looks back up to a week)."""
    now = time.time() if now is None else now
    out = []
    for back in range(8):
        day = _day(now - back * 86400)
        out.extend(reversed(events(day)))
        if len(out) >= n:
            break
    return out[:n]


def summary(day, moods):
    """Counts for one day. moods: [{id, name, group}] (the catalog) for names and groups."""
    info = {m['id']: m for m in moods}
    list_ = events(day)
    per = {}
    for owner in OWNERS:
        mine = [e for e in list_ if e['owner'] == owner]
        counts, groups = {}, {}
        for e in mine:
            counts[e['emotion']] = counts.get(e['emotion'], 0) + 1
            g = info.get(e['emotion'], {}).get('group', '기타')
            groups[g] = groups.get(g, 0) + 1
        top = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:3]
        per[owner] = dict(count=len(mine),
                          top=[dict(id=k, name=info.get(k, {}).get('name', k), count=v) for k, v in top],
                          groups=groups)
    timeline = [dict(t=e['t'], owner=e['owner'], emotion=e['emotion'],
                     name=info.get(e['emotion'], {}).get('name', e['emotion']),
                     group=info.get(e['emotion'], {}).get('group', '기타')) for e in list_]
    return dict(day=day, total=len(list_), owners=per, timeline=timeline)


def week(day):
    """Changes per owner for the 7 days ending on <day>: [{day, claude, gpt, user}]."""
    try:
        end = datetime.date.fromisoformat(day)
    except (ValueError, TypeError):
        end = datetime.date.today()
    out = []
    for back in range(6, -1, -1):
        d = (end - datetime.timedelta(days=back)).isoformat()
        list_ = events(d)
        row = dict(day=d)
        for owner in OWNERS:
            row[owner] = sum(1 for e in list_ if e['owner'] == owner)
        out.append(row)
    return out


def prune(now=None):
    """Remove day files older than KEEP_DAYS."""
    now = time.time() if now is None else now
    cutoff = _day(now - KEEP_DAYS * 86400)
    try:
        for name in os.listdir(FOLDER):
            if name.endswith('.jsonl') and name[:-6] < cutoff:
                (FOLDER / name).unlink()
    except OSError:
        pass
