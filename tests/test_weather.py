"""Weather selection, model parsing, safe fallbacks and board protocol without network."""
import datetime as dt
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import isolate
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'core'))
from aiface import weather, moods, paths
from aiface.board import Device

NOW = dt.datetime(2026, 11, 4, 20, tzinfo=dt.timezone.utc)
ROW = dict(weather_code=61, cloud_cover=85, precipitation=0.5,
           wind_speed_10m=8, wind_direction_10m=270)


class WeatherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        for name, obj, val in [('SETTINGS', moods, root / 'settings.json'), ('DATA', paths, root),
                               ('CACHE', weather, root / 'cache.json')]:
            p = patch.object(obj, name, val); p.start(); self.addCleanup(p.stop)
        self.c = weather.validate(weather.DEFAULT)
        with weather._lock:
            weather._state.update(scene={'active': False}, fetched=0, message='', loading=False, source='', sample='')

    def test_defaults_and_preservation(self):
        self.assertEqual(weather.config()['location']['timezone'], 'America/Los_Angeles')
        weather.save({'enabled': False})
        moods.save_settings(mono=True)
        self.assertFalse(weather.config()['enabled'])
        self.assertTrue(moods.load_settings()['mono'])

    def test_invalid_inputs(self):
        for change in [{'hour': 24}, {'hour': True}, {'mode': 'unknown'}, {'enabled': 1},
                       {'date': 'not-a-date'}, {'date': '1939-01-01'}, {'date': 1},
                       {'location': dict(weather.DEFAULT_LOCATION, latitude=float('nan'))},
                       {'location': dict(weather.DEFAULT_LOCATION, timezone='not/a_zone')},
                       {'location': {}}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                weather.validate(dict(self.c, **change))

    def test_six_conditions_and_no_probability_rain(self):
        for code, kind in [(0,0),(1,0),(2,1),(3,2),(45,5),(48,5),(51,3),(67,3),(82,3),(95,3),(99,3),(71,4),(86,4)]:
            self.assertEqual(weather.classify(code), kind)
        result = weather.parameters(dict(ROW, weather_code=2, precipitation_probability=100), True, 900)
        self.assertEqual((result['kind'], result['intensity'], result['day']), (1,0,100))
        with self.assertRaises(ValueError): weather.classify(999)

    def test_precipitation_interval_and_wind(self):
        a = weather.parameters(ROW, False, 900)
        b = weather.parameters(dict(ROW, precipitation=2), False, 3600)
        self.assertEqual(a, b)
        self.assertGreater(a['wind'], 0)  # westerly wind moves toward screen right
        self.assertGreater(a['intensity'], 0)
        self.assertLessEqual(a['intensity'], 100)
        with self.assertRaises(ValueError): weather.parameters(dict(ROW, cloud_cover=None), False, 900)

    def test_current_and_stale_model(self):
        row = dict(ROW, time=NOW.timestamp()-300, interval=900, is_day=1)
        with patch.object(weather, 'get_json', return_value={'current': row}) as get:
            scene, source, sample = weather.fetch(self.c, NOW)
            self.assertEqual(source, 'current'); self.assertEqual(scene['day'], 100)
            self.assertIn('current', get.call_args.args[1])
            self.assertEqual(get.call_args.args[1]['wind_speed_unit'], 'ms')
        row['time'] -= 7200
        with patch.object(weather, 'get_json', return_value={'current': row}):
            with self.assertRaises(ValueError): weather.fetch(self.c, NOW)

    def hourly(self, date, hour):
        from zoneinfo import ZoneInfo
        stamp = dt.datetime.fromisoformat(f'{date}T{hour:02d}:00').replace(tzinfo=ZoneInfo('America/Los_Angeles')).timestamp()
        return dict(hourly=dict(time=[stamp], **{k:[v] for k,v in ROW.items()}),
                    daily=dict(sunrise=[stamp-3600],sunset=[stamp+3600]))

    def test_selected_dates_and_dst(self):
        for date, source, host in [('2026-11-05','forecast','api.open-meteo.com'),
                                    ('2026-11-03','recent','api.open-meteo.com'),
                                    ('2026-10-20','historical','archive-api.open-meteo.com')]:
            with patch.object(weather, 'get_json', return_value=self.hourly(date,20)) as get:
                scene, got, sample = weather.fetch(dict(self.c,mode='date',date=date), NOW)
                self.assertEqual(got, source); self.assertIn(host,get.call_args.args[0])
                self.assertIn('20:00:00',sample)
                self.assertTrue(sample.endswith('-07:00') if date=='2026-10-20' else sample.endswith('-08:00'))
        with self.assertRaises(ValueError): weather.fetch(dict(self.c,mode='date',date='2026-12-01'), NOW)
        with patch.object(weather,'get_json',return_value=self.hourly('2026-11-03',19)):
            with self.assertRaises(ValueError): weather.fetch(dict(self.c,mode='date',date='2026-11-03'),NOW)

    def test_offline_cache_and_selection_change(self):
        device = Device()
        result = weather.parameters(ROW,False,900)
        with patch.object(weather,'fetch',return_value=(result,'current','sample')):
            weather.refresh(device)
        self.assertEqual(device.weather_scene,result)
        with patch.object(weather,'fetch',side_effect=OSError('offline')):
            weather.refresh(device)
        self.assertEqual(weather.scene(),result)
        self.assertIn('offline',weather.status()['message'])
        with patch.object(weather.time,'time',return_value=weather._state['fetched']+weather.STALE+1):
            self.assertFalse(weather.scene()['active'])
        weather.save({'mode':'date','date':'2026-11-03'})
        self.assertFalse(weather.scene()['active'])  # never display the previous selection as the new one

    def test_changed_config_during_fetch_is_discarded(self):
        def fetch(c):
            weather.save({'enabled':False})
            return weather.parameters(ROW,False,900),'current','sample'
        with patch.object(weather,'fetch',side_effect=fetch): weather.refresh(Device())
        self.assertFalse(weather.scene()['active'])

    def test_old_firmware_and_reconnect(self):
        d=Device();d.fd=1;d.touch=181
        scene=weather.parameters(ROW,False,900)
        with patch.object(d,'exchange',side_effect=ValueError('ERR COMMAND')) as exchange:
            d.set_weather(scene);d.set_weather(scene)
            self.assertEqual(exchange.call_count,1)
            self.assertFalse(d.weather_supported);self.assertEqual(d.touch,181)
        d.weather_supported=None
        with patch.object(d,'exchange',return_value='OK WEATHER') as exchange:
            d.set_weather(scene)
            self.assertTrue(d.weather_supported)
            self.assertTrue(exchange.call_args.args[0].startswith('WEATHER:1:3:0:85:'))
        d.fd=None

    def test_scene_is_retained_while_board_is_busy(self):
        d=Device()
        class BusyLock:
            def acquire(self, **kwargs): return False
        d.lock=BusyLock()
        result=weather.parameters(ROW,False,900)
        with patch.object(weather,'fetch',return_value=(result,'current','sample')):
            weather.refresh(d)
        self.assertEqual(d.weather_scene,result)

    def test_serial_failure_does_not_kill_worker(self):
        d=Device()
        with patch.object(weather,'fetch',return_value=(weather.parameters(ROW,False,900),'current','sample')), \
             patch.object(d,'set_weather',side_effect=OSError('serial lost')), patch.object(d,'close') as close:
            weather.refresh(d)
            close.assert_called_once()
        self.assertIn('serial lost',weather.status()['message'])


if __name__=='__main__': unittest.main()
