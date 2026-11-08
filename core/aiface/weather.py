"""Open-Meteo campfire weather. Fetch on the Mac; send small parameters, never video.
Current conditions are model estimates; selected dates use hourly forecasts/reanalysis.
"""
import datetime as dt
import json
import math
import threading
import time
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

from . import moods, paths
from .i18n import T

DEFAULT_LOCATION = dict(name='Palo Alto / Stanford', latitude=37.4275, longitude=-122.1697,
                        timezone='America/Los_Angeles')
DEFAULT = dict(enabled=True, mode='auto', date='', hour=20, location=DEFAULT_LOCATION)
KINDS = ('clear', 'partly_cloudy', 'overcast', 'rain', 'snow', 'fog')
INTERVAL = 4 * 3600  # ambient effects need only a few weather updates per day
STALE = 2 * 3600  # reject already-old model data when fetching
CACHE_TTL = 12 * 3600  # retain the last scene through the refresh interval/offline gaps
CACHE = paths.DATA / 'weather-cache.json'
_lock = threading.RLock()
_wake = threading.Event()
_state = dict(scene={'active': False}, message='', fetched=0, loading=False, source='', sample='')


def config():
    raw = moods.load_settings().get('weather', {})
    try:
        return validate(dict(DEFAULT, **raw))
    except (ValueError, TypeError):
        return dict(DEFAULT, location=dict(DEFAULT_LOCATION))


def validate(value):
    if not isinstance(value, dict):
        raise ValueError('Invalid weather settings')
    c = dict(DEFAULT, **value)
    if type(c['enabled']) is not bool or c['mode'] not in ('auto', 'date'):
        raise ValueError('Invalid weather mode')
    if type(c['hour']) is not int or not 0 <= c['hour'] <= 23:
        raise ValueError('Hour must be 0–23')
    if not isinstance(c['date'], str): raise ValueError('Invalid date')
    if c['date']:
        date = dt.date.fromisoformat(c['date'])
        if date < dt.date(1940, 1, 1):
            raise ValueError('Historical weather starts in 1940')
    elif c['mode'] == 'date':
        raise ValueError(T('날짜를 선택해 주세요.', 'Choose a date.'))
    location = c['location']
    if not isinstance(location, dict):
        raise ValueError('Choose a location')
    for key, bound in [('latitude', 90), ('longitude', 180)]:
        v = location.get(key)
        if type(v) not in (int, float) or not math.isfinite(v) or abs(v) > bound:
            raise ValueError('Invalid coordinates')
    if not isinstance(location.get('name'), str) or not isinstance(location.get('timezone'), str):
        raise ValueError('Invalid location')
    try:
        ZoneInfo(location['timezone'])
    except (KeyError, ValueError):
        raise ValueError('Invalid location timezone')
    c['location'] = {k: location[k] for k in DEFAULT_LOCATION}
    c['location']['name'] = str(c['location']['name'])[:100]
    return {k: c[k] for k in DEFAULT}


def save(value):
    c = validate(dict(config(), **value))
    moods.save_settings(weather=c)
    # Never show weather from the previous city/date while a new selection is loading.
    with _lock:
        _state.update(scene={'active': False}, fetched=0, message='', source='', sample='')
    _wake.set()
    return status()


def get_json(base, params):
    request = urllib.request.Request(base + '?' + urllib.parse.urlencode(params),
                                     headers={'User-Agent': 'AI-Face/2 campfire-weather'})
    with urllib.request.urlopen(request, timeout=12) as response:
        raw = response.read(2 << 20)
    data = json.loads(raw)
    if not isinstance(data, dict): raise ValueError('Invalid weather response')
    if data.get('error'):
        raise ValueError(data.get('reason', 'Weather service error'))
    return data


def locations(query):
    if not isinstance(query, str) or not 2 <= len(query.strip()) <= 100:
        raise ValueError(T('도시 이름을 2자 이상 입력해 주세요.', 'Enter at least two characters.'))
    data = get_json('https://geocoding-api.open-meteo.com/v1/search',
                    dict(name=query.strip(), count=8, language='en'))
    return [dict(name=', '.join(str(x[k]) for k in ('name', 'admin1', 'country') if x.get(k)),
                 latitude=x['latitude'], longitude=x['longitude'], timezone=x['timezone'])
            for x in data.get('results', []) if x.get('timezone')]


def number(row, key):
    v = row.get(key)
    if type(v) not in (int, float) or not math.isfinite(v):
        raise ValueError('Weather data unavailable: ' + key)
    return v


def classify(code):
    if code in (45, 48): return 5
    if code in (71, 73, 75, 77, 85, 86): return 4
    if code in (51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 97, 99): return 3
    if code == 3: return 2
    if code == 2: return 1
    if code in (0, 1): return 0
    raise ValueError('Unsupported weather code: ' + str(code))


def parameters(row, daylight, interval):
    code = number(row, 'weather_code')
    if code != int(code): raise ValueError('Invalid weather code')
    kind = classify(int(code))
    cloud = max(0, min(100, number(row, 'cloud_cover')))
    speed = max(0, number(row, 'wind_speed_10m'))  # request m/s explicitly
    direction = number(row, 'wind_direction_10m')
    # View is an illustrative east-west cross-section; wind direction is where wind comes FROM.
    lateral = -math.sin(math.radians(direction)) * min(speed / 12, 1)
    amount = max(0, number(row, 'precipitation')) * 3600 / interval
    # Always make coded light rain/snow visible, even if the model amount rounds to zero.
    strength = max(15, min(100, round(20 + 20 * math.sqrt(amount)))) if kind in (3, 4) else 0
    return dict(active=True, kind=kind, day=int(bool(daylight)) * 100, cloud=round(cloud),
                intensity=strength, wind=round(lateral * 100))


def fetch(c, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    loc = c['location']; zone = ZoneInfo(loc['timezone']); today = now.astimezone(zone).date()
    common = dict(latitude=loc['latitude'], longitude=loc['longitude'], timezone=loc['timezone'],
                  wind_speed_unit='ms', timeformat='unixtime')
    fields = 'weather_code,cloud_cover,precipitation,wind_speed_10m,wind_direction_10m'
    if c['mode'] == 'auto':
        data = get_json('https://api.open-meteo.com/v1/forecast', dict(common, current=fields + ',is_day'))
        row = data['current']; interval = number(row, 'interval')
        if not 0 < interval <= 3600: raise ValueError('Invalid weather time interval')
        sampled = number(row, 'time')
        if abs(sampled - now.timestamp()) > STALE:
            raise ValueError('Current weather data is too old')
        return parameters(row, number(row, 'is_day') == 1, interval), 'current', dt.datetime.fromtimestamp(sampled, zone).isoformat()
    date = dt.date.fromisoformat(c['date'])
    delta = (date - today).days
    if delta > 15:
        raise ValueError(T('미래 예보는 오늘부터 15일 뒤까지만 선택할 수 있습니다.',
                           'Forecast dates are available up to 15 days ahead.'))
    historical = delta < -5
    base = 'https://archive-api.open-meteo.com/v1/archive' if historical else 'https://api.open-meteo.com/v1/forecast'
    data = get_json(base, dict(common, start_date=c['date'], end_date=c['date'],
                               hourly=fields, daily='sunrise,sunset'))
    hourly = data['hourly']
    times = hourly['time']
    candidates = [i for i, t in enumerate(times) if
                  dt.datetime.fromtimestamp(t, zone).date() == date and
                  dt.datetime.fromtimestamp(t, zone).hour == c['hour']]
    if not candidates:
        raise ValueError(T('선택한 날짜·시간의 자료가 없습니다.', 'No data for the selected date and hour.'))
    index = candidates[0]; stamp = times[index]
    row = {k: values[index] for k, values in hourly.items() if k != 'time'}
    sunrise, sunset = data['daily']['sunrise'][0], data['daily']['sunset'][0]
    if not isinstance(sunrise, (int, float)) or not isinstance(sunset, (int, float)):
        raise ValueError('Sunrise/sunset data unavailable for the selected location')
    source = 'historical' if historical else ('forecast' if delta >= 0 else 'recent')
    return parameters(row, sunrise <= stamp < sunset, 3600), source, dt.datetime.fromtimestamp(stamp, zone).isoformat()


def scene():
    with _lock:
        if not config()['enabled'] or time.time() - _state['fetched'] > CACHE_TTL:
            return {'active': False}
        return dict(_state['scene'])


def status():
    with _lock:
        return dict(config=config(), scene=scene(), message=_state['message'], loading=_state['loading'],
                    fetched=_state['fetched'], source=_state['source'], sample=_state['sample'])


def refresh(device, stop=None):
    c = config()
    with _lock: _state['loading'] = True
    try:
        if c['enabled']:
            result, source, sample = fetch(c)
        else:
            result, source, sample = {'active': False}, '', ''
        if config() != c or (stop and stop.is_set()): return
        with _lock:
            _state.update(scene=result, source=source, sample=sample, fetched=time.time(), message='')
            # Cache is useful across an offline restart; it is keyed by the complete selection.
            paths.DATA.mkdir(parents=True, exist_ok=True)
            temp = CACHE.with_suffix('.tmp')
            temp.write_text(json.dumps(dict(config=c, **_state)))
            temp.replace(CACHE)
    except (OSError, ValueError, KeyError, TypeError, IndexError) as exc:
        if config() == c:
            with _lock: _state['message'] = str(exc)[:240]
    finally:
        with _lock: _state['loading'] = False
    if stop and stop.is_set(): return
    selected_scene = scene()
    # Reconnect/firmware upload can hold the serial lock; retain the latest scene for prepare().
    device.weather_scene = selected_scene
    if device.lock.acquire(timeout=1):
        try:
            device.set_weather(selected_scene)
        except (OSError, ValueError) as exc:
            device.close()
            with _lock: _state['message'] = str(exc)[:240]
        finally:
            device.lock.release()


def watch(device, stop):
    try:
        cached = json.loads(CACHE.read_text())
        if cached.get('config') == config() and time.time() - cached.get('fetched', 0) < CACHE_TTL:
            with _lock:
                for key in ('scene', 'source', 'sample', 'fetched'): _state[key] = cached[key]
    except (OSError, ValueError, KeyError, TypeError): pass
    while not stop.is_set():
        _wake.clear()
        refresh(device, stop)
        deadline = time.time() + INTERVAL
        while time.time() < deadline:
            if stop.wait(1) or _wake.is_set(): break
