"""Expression log: every face change (when, who chose it, which mood), one JSON line per
change in a file per day, and summaries for the app's 기록 tab and the get_expression
MCP tool. Only the mood is kept, never anything from the conversation.
Python standard library only."""
import datetime
import json
import os
import time

from . import paths

OTHER = 'other'   # group of a mood that is not in the catalog any more

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


def picks(n=5, known=None, now=None, days=60):
    """Moods the user picked by hand, newest first, each once (the menu's "Recent" list).
    AI choices are left out: they would fill the list with working moods. known: ids still
    in the catalog."""
    now = time.time() if now is None else now
    out = []
    for back in range(days):
        for e in reversed(events(_day(now - back * 86400))):
            mood = e['emotion']
            if e['owner'] == 'user' and mood not in out and (known is None or mood in known):
                out.append(mood)
                if len(out) >= n:
                    return out
    return out


def _owners(list_, info):
    """Per owner: how many changes, the top 3 moods and the count per emotion group."""
    per = {}
    for owner in OWNERS:
        mine = [e for e in list_ if e['owner'] == owner]
        counts, groups = {}, {}
        for e in mine:
            counts[e['emotion']] = counts.get(e['emotion'], 0) + 1
            g = info.get(e['emotion'], {}).get('group_id', OTHER)
            groups[g] = groups.get(g, 0) + 1
        top = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:3]
        per[owner] = dict(count=len(mine),
                          top=[dict(id=k, name=info.get(k, {}).get('name', k), count=v) for k, v in top],
                          groups=groups)
    return per


def _timeline(list_, info):
    return [dict(t=e['t'], owner=e['owner'], emotion=e['emotion'],
                 name=info.get(e['emotion'], {}).get('name', e['emotion']),
                 group=info.get(e['emotion'], {}).get('group_id', OTHER)) for e in list_]


def summary(day, moods):
    """Counts for one day. moods: [{id, name, group}] (the catalog) for names and groups."""
    info = {m['id']: m for m in moods}
    list_ = events(day)
    return dict(day=day, total=len(list_), owners=_owners(list_, info), timeline=_timeline(list_, info))


KINDS = ('day', 'week', 'month', 'year')


def period_range(kind, day):
    """First and last date of the day, week (Monday to Sunday), month or year holding <day>."""
    try:
        d = datetime.date.fromisoformat(day)
    except (ValueError, TypeError):
        d = datetime.date.today()
    if kind == 'week':
        start = d - datetime.timedelta(days=d.weekday())
        return start, start + datetime.timedelta(days=6)
    if kind == 'month':
        start = d.replace(day=1)
        following = (start + datetime.timedelta(days=32)).replace(day=1)
        return start, following - datetime.timedelta(days=1)
    if kind == 'year':
        return datetime.date(d.year, 1, 1), datetime.date(d.year, 12, 31)
    return d, d


def period(kind, day, moods):
    """Counts for the day, week, month or year holding <day>, plus what its chart needs:
    day -> timeline (every change); week -> rows per day, each with its changes' times;
    month -> rows per day with counts per owner; year -> rows per month with counts."""
    kind = kind if kind in KINDS else 'day'
    info = {m['id']: m for m in moods}
    start, end = period_range(kind, day)
    last = min(end, datetime.date.today())
    days = {}
    d = start
    while d <= last:
        days[d.isoformat()] = events(d.isoformat())
        d += datetime.timedelta(days=1)
    every = [e for list_ in days.values() for e in list_]

    def counts(list_):
        return {owner: sum(1 for e in list_ if e['owner'] == owner) for owner in OWNERS}

    rows = []
    if kind == 'week':
        for back in range(7):
            key = (start + datetime.timedelta(days=back)).isoformat()
            rows.append(dict(day=key, timeline=[dict(t=e['t'], owner=e['owner']) for e in days.get(key, [])]))
    elif kind == 'month':
        d = start
        while d <= end:
            rows.append(dict(day=d.isoformat(), **counts(days.get(d.isoformat(), []))))
            d += datetime.timedelta(days=1)
    elif kind == 'year':
        for month in range(1, 13):
            prefix = f'{start.year:04d}-{month:02d}'
            rows.append(dict(day=prefix, **counts([e for k, list_ in days.items() if k.startswith(prefix) for e in list_])))
    return dict(kind=kind, start=start.isoformat(), end=end.isoformat(), total=len(every),
                owners=_owners(every, info), timeline=_timeline(every, info) if kind == 'day' else [], rows=rows)


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


def clear():
    """Delete the whole history. Returns how many changes were removed."""
    removed = 0
    try:
        names = os.listdir(FOLDER)
    except OSError:
        return 0
    for name in names:
        if name.endswith('.jsonl'):
            removed += len(events(name[:-6]))
            try:
                (FOLDER / name).unlink()
            except OSError:
                pass
    return removed


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
