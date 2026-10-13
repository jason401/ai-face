"""Read the Mac's calendars (Calendar.app, Exchange included) for the AIs, read only.

EventKit only works from Swift, so the app binary answers in a command mode
(`AI Face.app/Contents/MacOS/AIFace --calendar ...`, see app/macos/Calendar.swift); being the
app itself, it uses the calendar permission the user gave AI Face.

The user decides in the app which AIs may read the calendar (claude / gpt), which calendars
they see, and whether notes and attendees are included (off by default: meeting notes often
hold passcodes, and attendee lists other people's details). Python standard library only.
"""
import datetime
import json
import re
import subprocess

from . import moods as settings_store
from . import paths
from .i18n import T

DEFAULTS = dict(apps=dict(claude=True, gpt=False), hidden=[], details=False)
MAX_DAYS = 62


def binary():
    root = paths.project_root()
    return root / 'AI Face.app' / 'Contents' / 'MacOS' / 'AIFace' if root else None


def _run(*args, timeout=20):
    exe = binary()
    if exe is None or not exe.exists():
        raise ValueError(T('AI Face 앱을 찾지 못했습니다.', 'The AI Face app was not found.'))
    try:
        p = subprocess.run([str(exe), '--calendar', *args], stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=timeout)
        return json.loads(p.stdout)
    except subprocess.TimeoutExpired:
        raise ValueError(T('캘린더가 응답하지 않습니다.', 'The calendar did not answer in time.'))
    except (OSError, ValueError):
        raise ValueError(T('캘린더를 읽지 못했습니다.', 'Could not read the calendar.'))


def _calendars():
    result = _run('calendars')
    if isinstance(result, dict) and result.get('error') == 'no_access':
        raise PermissionError(T('AI Face에 캘린더 권한이 없습니다 (설정 → AI 연결 → 캘린더).',
                                'AI Face has no calendar access yet (Settings → AI apps → Calendar).'))
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
    return out


def save(changes):
    """changes: any of apps {claude, gpt: bool}, hidden [calendar ids], details bool."""
    current = settings()
    if not isinstance(changes, dict):
        raise ValueError(T('잘못된 요청입니다.', 'Bad request.'))
    if isinstance(changes.get('apps'), dict):
        current['apps'].update({k: v is True for k, v in changes['apps'].items() if k in current['apps']})
    if isinstance(changes.get('hidden'), list):
        current['hidden'] = [x for x in changes['hidden'] if isinstance(x, str)][:200]
    if 'details' in changes:
        current['details'] = changes['details'] is True
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
            cals = [dict(c, shown=c['id'] not in conf['hidden']) for c in _calendars()]
        except (ValueError, PermissionError):
            cals = []
    return dict(access=access, calendars=cals, **conf)


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
        raise PermissionError(T('이 AI는 캘린더를 읽도록 허용되지 않았습니다 (AI Face 설정 → AI 연결).',
                                'This AI is not allowed to read the calendar (AI Face settings → AI apps).'))
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
        raise PermissionError(T('AI Face에 캘린더 권한이 없습니다 (설정 → AI 연결 → 캘린더).',
                                'AI Face has no calendar access yet (Settings → AI apps → Calendar).'))
    if not isinstance(result, list):
        raise ValueError(T('캘린더를 읽지 못했습니다.', 'Could not read the calendar.'))
    if query:
        q = str(query).lower()
        result = [e for e in result if q in (e.get('title', '') + ' ' + e.get('location', '')).lower()]
    head = f"{begin:%Y-%m-%d %a} – {(finish - datetime.timedelta(seconds=1)):%Y-%m-%d %a} (local time)"
    if not result:
        return head + '\nNo events.'
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
        lines.append(line)
    return '\n'.join(lines)


def calendar_names(agent):
    if not allowed(agent):
        raise PermissionError(T('이 AI는 캘린더를 읽도록 허용되지 않았습니다.', 'This AI is not allowed to read the calendar.'))
    conf = settings()
    cals = [c for c in _calendars() if c['id'] not in conf['hidden']]
    return '\n'.join(f"- {c['title']} ({c.get('account', '')}, {c.get('kind', '')})" for c in cals) or 'No calendars.'
