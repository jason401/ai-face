"""The Mac's calendars (Calendar.app, Exchange included) for the AIs: reading, and adding /
changing / deleting events the user allows.

EventKit only works from Swift, so the app binary answers in a command mode
(`AI Face.app/Contents/MacOS/AIFace --calendar ...`, see app/macos/Calendar.swift); being the
app itself, it uses the calendar permission the user gave AI Face.

The user decides in the app which AIs may read the calendar (claude / gpt), which calendars
they see, and whether notes and attendees are included (off by default: meeting notes often
hold passcodes, and attendee lists other people's details).

Writing is separate: which AIs may write (off by default), which calendars they may write to
(default: the Calendar app's default calendar), and whether every change waits for the user's
OK in a window AI Face shows (on by default). AIs can change or delete only events added
through AI Face (tagged in their notes). Every change is logged and can be undone from the
settings. Python standard library only.
"""
import datetime
import json
import re
import subprocess
import threading
import time
import uuid

from . import moods as settings_store
from . import paths
from .i18n import T

DEFAULTS = dict(apps=dict(claude=True, gpt=False), hidden=[], details=False,
                write_apps=dict(claude=False, gpt=False), writable=None, confirm=True)
LOG = paths.DATA / 'calendar_changes.json'   # recent changes, for undo
CONFIRM_SECONDS = 45   # under the chat apps' tool time limit; a late answer changes nothing
MAX_DAYS = 62


def binary():
    root = paths.project_root()
    return root / 'AI Face.app' / 'Contents' / 'MacOS' / 'AIFace' if root else None


def _run(*args, timeout=20, data=None):
    exe = binary()
    if exe is None or not exe.exists():
        raise ValueError(T('AI Face 앱을 찾지 못했습니다.', 'The AI Face app was not found.'))
    try:
        p = subprocess.run([str(exe), '--calendar', *args], input=json.dumps(data) if data is not None else '',
                           capture_output=True, text=True, timeout=timeout)
        return json.loads(p.stdout)
    except subprocess.TimeoutExpired:
        raise ValueError(T('캘린더가 응답하지 않습니다.', 'The calendar did not answer in time.'))
    except (OSError, ValueError):
        raise ValueError(T('캘린더를 읽지 못했습니다.', 'Could not read the calendar.'))


def _calendars():
    result = _run('calendars')
    if isinstance(result, dict) and result.get('error') == 'no_access':
        raise PermissionError(T('AI Face에 캘린더 권한이 없습니다 (설정 → 캘린더).',
                                'AI Face has no calendar access yet (Settings → Calendar).'))
    if not isinstance(result, list):
        raise ValueError(T('캘린더를 읽지 못했습니다.', 'Could not read the calendar.'))
    return [c for c in result if isinstance(c, dict) and isinstance(c.get('id'), str)]


def settings():
    data = settings_store.load_settings().get('calendar')
    out = json.loads(json.dumps(DEFAULTS))
    if isinstance(data, dict):
        if isinstance(data.get('apps'), dict):
            out['apps'].update({k: v is True for k, v in data['apps'].items() if k in out['apps']})
        if isinstance(data.get('hidden'), list):
            out['hidden'] = [x for x in data['hidden'] if isinstance(x, str)]
        out['details'] = data.get('details') is True
        if isinstance(data.get('write_apps'), dict):
            out['write_apps'].update({k: v is True for k, v in data['write_apps'].items() if k in out['write_apps']})
        if isinstance(data.get('writable'), list):
            out['writable'] = [x for x in data['writable'] if isinstance(x, str)]
        out['confirm'] = data.get('confirm') is not False
    return out


def save(changes):
    """changes: any of apps / write_apps {claude, gpt: bool}, hidden [calendar ids], writable
    [calendar ids], details bool, confirm bool."""
    current = settings()
    if not isinstance(changes, dict):
        raise ValueError(T('잘못된 요청입니다.', 'Bad request.'))
    if isinstance(changes.get('apps'), dict):
        current['apps'].update({k: v is True for k, v in changes['apps'].items() if k in current['apps']})
    if isinstance(changes.get('hidden'), list):
        current['hidden'] = [x for x in changes['hidden'] if isinstance(x, str)][:200]
    if 'details' in changes:
        current['details'] = changes['details'] is True
    if isinstance(changes.get('write_apps'), dict):
        current['write_apps'].update({k: v is True for k, v in changes['write_apps'].items()
                                      if k in current['write_apps']})
    if isinstance(changes.get('writable'), list):
        current['writable'] = [x for x in changes['writable'] if isinstance(x, str)][:200]
    if 'confirm' in changes:
        current['confirm'] = changes['confirm'] is not False
    settings_store.save_settings(calendar=current)
    return current


def status():
    """For the settings window: permission, calendars (with hidden flags) and the choices."""
    conf = settings()
    try:
        access = _run('status', timeout=10).get('status', 'unknown')
    except ValueError:
        access = 'unavailable'
    cals = []
    if access == 'full':
        try:
            all_cals = _calendars()
            targets = {c['id'] for c in _targets(all_cals, conf)}
            cals = [dict(c, shown=c['id'] not in conf['hidden'], write=c['id'] in targets) for c in all_cals]
        except (ValueError, PermissionError):
            cals = []
    return dict(access=access, calendars=cals, changes=recent_changes(), **conf)


def _targets(cals, conf):
    """Calendars the AIs may write to: the user's choice, else the Calendar app's default."""
    if conf['writable'] is None:
        return [c for c in cals if c.get('default') and c.get('writable')]
    return [c for c in cals if c['id'] in conf['writable'] and c.get('writable')]


def can_write(agent):
    return settings()['write_apps'].get(agent, False) is True


def allowed(agent):
    return settings()['apps'].get(agent, False) is True


SECRET = re.compile(r'(password|passcode|passwd|pwd|pin|암호|비밀번호)\s*[:=]?\s*\S+', re.I)
URL = re.compile(r'https?://([^/\s?#]+)\S*', re.I)


def place(text, details):
    """The event's location on one line. Without details, meeting links keep only their host
    (Zoom links often carry the passcode) and anything like "Password: 123" is dropped."""
    text = ' '.join(str(text or '').split())
    if not details:
        text = SECRET.sub('', URL.sub(lambda m: m.group(1) + ' link', text))
        text = ' '.join(text.split())
    return text[:200]


def _day(value, default):
    if value in (None, ''):
        return default
    try:
        return datetime.datetime.fromisoformat(str(value))
    except ValueError:
        raise ValueError(T(f'날짜 형식이 올바르지 않습니다: {value} (예: 2026-10-15)',
                           f'Bad date: {value} (use e.g. 2026-10-15)'))


def events(agent, start=None, end=None, query=None, now=None):
    """Events as text lines for an AI. start/end: 'YYYY-MM-DD' or ISO date-time (local time);
    default today; an end date alone is inclusive."""
    if not allowed(agent):
        raise PermissionError(T('이 AI는 캘린더를 읽도록 허용되지 않았습니다 (AI Face 설정 → 캘린더).',
                                'This AI is not allowed to read the calendar (AI Face settings → Calendar).'))
    now = now or datetime.datetime.now()
    today = datetime.datetime(now.year, now.month, now.day)
    begin = _day(start, today)
    finish = _day(end, None)
    if finish is None:
        finish = begin + datetime.timedelta(days=1)
    elif len(str(end)) <= 10:   # a date: the whole day
        finish += datetime.timedelta(days=1)
    if finish <= begin:
        raise ValueError(T('끝이 시작보다 빠릅니다.', 'The end is before the start.'))
    if finish - begin > datetime.timedelta(days=MAX_DAYS):
        raise ValueError(T(f'한 번에 {MAX_DAYS}일까지만 읽을 수 있습니다.', f'At most {MAX_DAYS} days at a time.'))
    conf = settings()
    cals = [c for c in _calendars() if c['id'] not in conf['hidden']]
    if not cals:
        return T('보여줄 캘린더가 없습니다.', 'No calendars to show.')
    result = _run('events', str(begin.timestamp()), str(finish.timestamp()),
                  ','.join(c['id'] for c in cals), 'details' if conf['details'] else '-')
    if isinstance(result, dict) and result.get('error') == 'no_access':
        raise PermissionError(T('AI Face에 캘린더 권한이 없습니다 (설정 → 캘린더).',
                                'AI Face has no calendar access yet (Settings → Calendar).'))
    if not isinstance(result, list):
        raise ValueError(T('캘린더를 읽지 못했습니다.', 'Could not read the calendar.'))
    if query:
        q = str(query).lower()
        result = [e for e in result if q in (e.get('title', '') + ' ' + e.get('location', '')).lower()]
    head = f"{begin:%Y-%m-%d %a} – {(finish - datetime.timedelta(seconds=1)):%Y-%m-%d %a} (local time)"
    if not result:
        return head + '\nNo events.'
    writer = can_write(agent)
    lines = [head]
    for e in result:
        s = datetime.datetime.fromtimestamp(e['start'])
        f = datetime.datetime.fromtimestamp(e['end'])
        if e.get('all_day'):
            last = f - datetime.timedelta(seconds=1)   # all-day events end at the next midnight
            when = f"{s:%m-%d %a} all day" if last.date() <= s.date() else f"{s:%m-%d %a} – {last:%m-%d %a} all day"
        elif s.date() == f.date():
            when = f"{s:%m-%d %a} {s:%H:%M}–{f:%H:%M}"
        else:
            when = f"{s:%m-%d %a %H:%M} – {f:%m-%d %a %H:%M}"
        line = f"- {when} {e.get('title') or '(no title)'}"
        where = place(e.get('location'), conf['details'])
        if where:
            line += f" @ {where}"
        line += f" [{e.get('calendar', '')}]"
        if e.get('attendees'):
            line += ' with ' + ', '.join(e['attendees'])
        if e.get('notes'):
            line += '\n    notes: ' + ' '.join(e['notes'].split())[:600]
        if writer and e.get('id'):
            line += f" #{_short(e['id'], e['start'])}" + (' (added via AI Face: you may change it)' if e.get('ours') else '')
        lines.append(line)
    return '\n'.join(lines)


def calendar_names(agent):
    if not allowed(agent):
        raise PermissionError(T('이 AI는 캘린더를 읽도록 허용되지 않았습니다.', 'This AI is not allowed to read the calendar.'))
    conf = settings()
    cals = [c for c in _calendars() if c['id'] not in conf['hidden']]
    return '\n'.join(f"- {c['title']} ({c.get('account', '')}, {c.get('kind', '')})" for c in cals) or 'No calendars.'


# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------
_ids = {}          # short id ("e7") -> (event identifier, occurrence start)
_ids_back = {}
_pending = {}      # confirmation id -> dict(text, agent, done: Event, allow)
_lock = threading.Lock()


def _short(event_id, start):
    key = (event_id, float(start))
    with _lock:
        if key not in _ids_back:
            short = f'e{len(_ids) + 1}'
            _ids[short] = key
            _ids_back[key] = short
        return _ids_back[key]


def _when(start, end, all_day):
    s, f = datetime.datetime.fromtimestamp(start), datetime.datetime.fromtimestamp(end)
    if all_day:
        last = f - datetime.timedelta(seconds=1)
        return f"{s:%m-%d %a} all day" if last.date() <= s.date() else f"{s:%m-%d %a} – {last:%m-%d %a} all day"
    if s.date() == f.date():
        return f"{s:%m-%d %a} {s:%H:%M}–{f:%H:%M}"
    return f"{s:%m-%d %a %H:%M} – {f:%m-%d %a %H:%M}"


def _summary(e):
    text = f"{_when(e['start'], e['end'], e.get('all_day'))} {e.get('title') or '(no title)'}"
    if e.get('location'):
        text += f" @ {' '.join(str(e['location']).split())[:80]}"
    return text + f" [{e.get('calendar', '')}]"


def _time(value, name):
    if value in (None, ''):
        return None
    try:
        return datetime.datetime.fromisoformat(str(value))
    except ValueError:
        raise ValueError(T(f'{name} 형식이 올바르지 않습니다: {value} (예: 2026-10-15T14:00)',
                           f'Bad {name}: {value} (use e.g. 2026-10-15T14:00)'))


def _fields(args, current=None):
    """Event fields from an AI's arguments (local times), checked."""
    out = {}
    if args.get('title') is not None:
        title = ' '.join(str(args['title']).split())
        if not 1 <= len(title) <= 200:
            raise ValueError(T('제목은 1~200자여야 합니다.', 'The title must be 1-200 characters.'))
        out['title'] = title
    all_day = args.get('all_day')
    if all_day is not None:
        out['all_day'] = all_day is True
    start, end = _time(args.get('start'), 'start'), _time(args.get('end'), 'end')
    day_only = out.get('all_day', (current or {}).get('all_day', False))
    if start is not None:
        if day_only:
            start = datetime.datetime(start.year, start.month, start.day)
        out['start'] = start.timestamp()
    if end is not None:
        if day_only:   # EventKit: an all-day event ends on its last day (start = end for one day)
            end = datetime.datetime(end.year, end.month, end.day)
        out['end'] = end.timestamp()
    s = out.get('start', (current or {}).get('start'))
    f = out.get('end', (current or {}).get('end'))
    if s is not None and 'end' not in out and current is None:
        f = out['end'] = s if day_only else s + 3600
    if s is not None and f is not None and (f < s if day_only else f <= s):
        raise ValueError(T('끝이 시작보다 빠릅니다.', 'The end is before the start.'))
    for key in ('location', 'notes'):
        if args.get(key) is not None:
            out[key] = str(args[key])[:2000]
    return out


def _confirm(agent, text):
    """Show the change in AI Face and wait for the user's answer (when confirmation is on)."""
    if not settings()['confirm']:
        return
    rid = uuid.uuid4().hex[:8]
    item = dict(id=rid, agent=agent, text=text, done=threading.Event(), allow=None, t=time.time())
    with _lock:
        _pending[rid] = item
    try:
        if not item['done'].wait(CONFIRM_SECONDS):
            raise PermissionError(T('사용자가 확인 창에 답하지 않아 바꾸지 않았습니다.',
                                    'The user did not answer the confirmation, so nothing was changed.'))
        if not item['allow']:
            raise PermissionError(T('사용자가 거절해서 바꾸지 않았습니다.', 'The user declined, so nothing was changed.'))
    finally:
        with _lock:
            _pending.pop(rid, None)


def pending():
    """Confirmations waiting for the user (shown by the menu bar app)."""
    with _lock:
        return [dict(id=p['id'], agent=p['agent'], text=p['text']) for p in _pending.values()]


def decide(rid, allow):
    with _lock:
        item = _pending.get(rid)
    if item is None:
        raise ValueError(T('이미 끝난 요청입니다.', 'That request is no longer waiting.'))
    item['allow'] = allow is True
    item['done'].set()


def _who(agent):
    return {'claude': 'Claude', 'gpt': 'GPT'}.get(agent, agent)


def _write(command, data):
    result = _run(command, data=data, timeout=30)
    if not isinstance(result, dict):
        raise ValueError(T('캘린더를 바꾸지 못했습니다.', 'Could not change the calendar.'))
    error = result.get('error')
    if error == 'not_ours':
        raise PermissionError(T('AI Face로 추가한 일정만 바꾸거나 지울 수 있습니다.',
                                'Only events added through AI Face can be changed or deleted.'))
    if error == 'not_found':
        raise ValueError(T('그 일정을 찾지 못했습니다. 일정을 다시 읽어 주세요.',
                           'That event was not found. Read the calendar again.'))
    if error == 'no_access':
        raise PermissionError(T('AI Face에 캘린더 권한이 없습니다.', 'AI Face has no calendar access.'))
    if error:
        raise ValueError(T(f'캘린더를 바꾸지 못했습니다: {result.get("message", error)}',
                           f'Could not change the calendar: {result.get("message", error)}'))
    return result


def _log(agent, op, before=None, after=None):
    entries = _load_log()
    n = (entries[-1]['n'] + 1) if entries else 1
    entries.append(dict(n=n, t=time.time(), agent=agent, op=op, before=before, after=after, undone=False))
    LOG.parent.mkdir(parents=True, exist_ok=True)
    temp = LOG.with_suffix('.tmp')
    temp.write_text(json.dumps(entries[-50:], ensure_ascii=False))
    temp.replace(LOG)


def _load_log():
    try:
        data = json.loads(LOG.read_text())
        return [e for e in data if isinstance(e, dict) and 'n' in e] if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def recent_changes(limit=10):
    out = []
    for e in reversed(_load_log()[-limit:]):
        event = e.get('after') or e.get('before') or {}
        verb = {'add': T('추가', 'Added'), 'update': T('변경', 'Changed'), 'delete': T('삭제', 'Deleted')}[e['op']]
        when = datetime.datetime.fromtimestamp(e['t']).strftime('%m-%d %H:%M')
        out.append(dict(n=e['n'], undone=e.get('undone', False),
                        text=f"{when} {_who(e['agent'])} · {verb}: {_summary(event) if event else ''}"))
    return out


def _require_writer(agent):
    if not can_write(agent):
        raise PermissionError(T('이 AI는 캘린더를 바꾸도록 허용되지 않았습니다 (AI Face 설정 → 캘린더 → 쓰기).',
                                'This AI is not allowed to change the calendar (AI Face settings → Calendar → Writing).'))


def _target(conf, name):
    targets = _targets(_calendars(), conf)
    if not targets:
        raise PermissionError(T('쓰기가 허용된 캘린더가 없습니다 (설정 → 캘린더 → 쓰기).',
                                'No calendar is open for writing (Settings → Calendar → Writing).'))
    if not name:
        default = [c for c in targets if c.get('default')]
        return (default or targets)[0]
    label = lambda c: f"{c['title']} ({c.get('account', '')})"
    wanted = ' '.join(str(name).split()).lower()
    found = [c for c in targets if label(c).lower() == wanted] or [c for c in targets if c['title'].lower() == wanted]
    if len(found) == 1:
        return found[0]
    if len(found) > 1:   # the same name in two accounts: ask for "Name (Account)"
        raise ValueError(T('같은 이름의 캘린더가 여럿입니다. 계정까지 적어 주세요: ',
                           'Several calendars have that name; give the account too: ') + ', '.join(label(c) for c in found))
    raise PermissionError(T(f'"{name}" 캘린더에는 쓸 수 없습니다. 가능한 캘린더: ',
                            f'Cannot write to "{name}". Allowed: ') + ', '.join(label(c) for c in targets))


def add(agent, args):
    _require_writer(agent)
    conf = settings()
    fields = _fields(args)
    if 'title' not in fields or 'start' not in fields:
        raise ValueError(T('제목과 시작 시각이 필요합니다.', 'A title and a start are needed.'))
    cal = _target(conf, args.get('calendar'))
    same = [e for e in (_around(fields['start']) or []) if isinstance(e, dict) and e.get('calendar_id') == cal['id']
            and abs(e['start'] - fields['start']) < 1 and e.get('title') == fields['title']]
    if same:   # a retry or a repeated request: do not add it twice
        return 'Already there (not added again): ' + _summary(same[0]) + f" #{_short(same[0]['id'], same[0]['start'])}"
    preview = dict(fields, calendar=cal['title'])
    _confirm(agent, T(f"{_who(agent)}가 일정을 추가하려고 해요:\n", f"{_who(agent)} wants to add an event:\n") + _summary(preview))
    result = _write('add', dict(fields, calendar_id=cal['id']))
    _log(agent, 'add', after=result['event'])
    e = result['event']
    return 'Added: ' + _summary(e) + f" #{_short(e['id'], e['start'])}"


def _event(short):
    with _lock:
        key = _ids.get(str(short).lstrip('#'))
    if key is None:
        raise ValueError(T('모르는 일정 번호입니다. 먼저 calendar_events로 읽어 주세요.',
                           'Unknown event id. Read the calendar first (calendar_events).'))
    return key


def _around(occurrence):
    """Every event on the day of `occurrence` (local) and the next, with details."""
    day = datetime.datetime.fromtimestamp(occurrence)
    day = datetime.datetime(day.year, day.month, day.day).timestamp()
    return _run('events', str(day), str(day + 2 * 86400), '-', 'details')


def update(agent, short, args):
    _require_writer(agent)
    conf = settings()
    event_id, occurrence = _event(short)
    current = _around(occurrence)
    current = next((e for e in current if isinstance(e, dict) and e.get('id') == event_id
                    and abs(e['start'] - occurrence) < 1), None) if isinstance(current, list) else None
    if current is None:
        raise ValueError(T('그 일정을 찾지 못했습니다. 일정을 다시 읽어 주세요.', 'That event was not found. Read the calendar again.'))
    if not current.get('ours'):
        raise PermissionError(T('AI Face로 추가한 일정만 바꿀 수 있습니다.', 'Only events added through AI Face can be changed.'))
    if current.get('recurring'):
        raise PermissionError(T('반복 일정은 AI가 바꿀 수 없습니다. 캘린더 앱에서 직접 바꿔 주세요.',
                                'Repeating events cannot be changed by an AI; change it in the Calendar app.'))
    fields = _fields(args, current)
    if args.get('calendar'):
        fields['calendar_id'] = _target(conf, args['calendar'])['id']
    if not fields:
        raise ValueError(T('바꿀 내용이 없습니다.', 'Nothing to change.'))
    preview = dict(current, **fields)
    _confirm(agent, T(f"{_who(agent)}가 일정을 바꾸려고 해요:\n", f"{_who(agent)} wants to change an event:\n")
             + _summary(current) + '\n→ ' + _summary(preview))
    result = _write('update', dict(fields, id=event_id, occurrence=occurrence))
    _log(agent, 'update', before=result.get('before'), after=result.get('event'))
    e = result['event']
    return 'Changed: ' + _summary(e) + f" #{_short(e['id'], e['start'])}"


def delete(agent, short):
    _require_writer(agent)
    event_id, occurrence = _event(short)
    found = _around(occurrence)
    current = next((e for e in found if isinstance(e, dict) and e.get('id') == event_id
                    and abs(e['start'] - occurrence) < 1), None) if isinstance(found, list) else None
    if current is None:
        raise ValueError(T('그 일정을 찾지 못했습니다.', 'That event was not found.'))
    if not current.get('ours'):
        raise PermissionError(T('AI Face로 추가한 일정만 지울 수 있습니다.', 'Only events added through AI Face can be deleted.'))
    if current.get('recurring'):
        raise PermissionError(T('반복 일정은 AI가 지울 수 없습니다. 캘린더 앱에서 직접 지워 주세요.',
                                'Repeating events cannot be deleted by an AI; delete it in the Calendar app.'))
    _confirm(agent, T(f"{_who(agent)}가 일정을 지우려고 해요:\n", f"{_who(agent)} wants to delete an event:\n") + _summary(current))
    result = _write('delete', dict(id=event_id, occurrence=occurrence))
    _log(agent, 'delete', before=result.get('before'))
    return 'Deleted: ' + _summary(current)


def undo(n):
    """The user undoes logged change n (no confirmation: the user asked for it)."""
    entries = _load_log()
    entry = next((e for e in entries if e['n'] == n), None)
    if entry is None or entry.get('undone'):
        raise ValueError(T('되돌릴 수 없는 변경입니다.', 'That change cannot be undone.'))
    before, after = entry.get('before') or {}, entry.get('after') or {}
    keys = ('title', 'start', 'end', 'all_day', 'location')
    if entry['op'] in ('add', 'update'):   # refuse if it was changed since (by hand or by an AI)
        now_ = next((e for e in (_around(after['start']) or []) if isinstance(e, dict)
                     and e.get('id') == after.get('id') and abs(e['start'] - after['start']) < 1), None)
        if now_ is None or any(now_.get(k) != after.get(k) for k in keys):
            raise ValueError(T('그 뒤에 일정이 바뀌었거나 지워져서 되돌리지 않았습니다.',
                               'The event changed or was removed since, so it was not undone.'))
    if entry['op'] == 'add':
        _write('delete', dict(id=after['id'], occurrence=after['start']))
    elif entry['op'] == 'delete':
        _write('add', dict({k: before[k] for k in keys if k in before}, notes=before.get('notes', ''),
                           calendar_id=before.get('calendar_id')))
    else:
        _write('update', dict({k: before[k] for k in keys if k in before}, calendar_id=before.get('calendar_id'),
                              id=after['id'], occurrence=after['start']))
    for e in entries:
        if e['n'] == n:
            e['undone'] = True
    LOG.write_text(json.dumps(entries, ensure_ascii=False))
