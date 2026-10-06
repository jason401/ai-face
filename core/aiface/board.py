"""The ESP32 board over USB serial (FACE8 protocol) plus what the face shows when no
board is attached (the menu bar). Python standard library only."""
import datetime
import importlib
import fcntl
import glob
import os
import select
import termios
import threading
import time

from . import flasher
from . import history
from .i18n import T
from . import moods as face_modes


WORKING_LIMIT = 180   # seconds a working mood may stay before the face returns to calm


def ports():
    return sorted(set(glob.glob('/dev/cu.usbmodem*') +
                      glob.glob('/dev/cu.usbserial*') + glob.glob('/dev/cu.wchusbserial*') +
                      glob.glob('/dev/cu.SLAB_USBtoUART*')))


class Device:
    def __init__(self, expect_ack=True):
        # FACE8 requires acknowledgments; older firmware must be updated once.
        self.expect_ack = expect_ack
        self.fd = None
        self.port = ''
        self.mode = ''
        self.emotion = ''
        self.owner = ''  # user / claude / gpt: who chose the current face
        self.photos = []  # photo ids stored on the board
        self.current_photo = -1
        # What the face should show even with no board (menu bar): the last chosen screen.
        self.screen = 'face'          # face / clock / fire / photo
        self.changed = time.time()    # when the face last changed (screen saver countdown)
        self.message = T('보드 없음 · 표정은 메뉴바 얼굴에 표시돼요. 보드를 꽂으면 자동으로 연결해요.',
                         'No board. The face shows in the menu bar; plug a board in and it connects by itself.')
        self.lock = threading.RLock()
        self.buffer = b''
        self.paused = False   # 'disconnect' until 'connect': no automatic reconnect
        self.flashing = False

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
        self.fd = None
        self.port = ''
        self.mode = ''

    def exchange(self, command, expected, payload=b''):
        """Send one line and wait for its reply. An expected value ending in ':' is a
        prefix (e.g. 'OK SUM:'); the full reply line is returned."""
        if self.fd is None:
            raise ValueError(T('먼저 ESP32에 연결해 주세요.', 'Connect the ESP32 first.'))
        packet = (command + '\n').encode('ascii') + payload   # raw bytes follow the line
        deadline = time.monotonic() + 3
        while packet:
            if time.monotonic() > deadline:
                raise TimeoutError(T('명령 전송 시간이 초과되었습니다.', 'Sending the command timed out.'))
            _, writable, _ = select.select([], [self.fd], [], 0.1)
            if writable:
                packet = packet[os.write(self.fd, packet):]
        if not self.expect_ack:
            return
        while time.monotonic() < deadline:
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                reply = line.strip().decode('utf-8', 'replace')
                if reply == 'ERR FS':
                    raise ValueError(T('보드 저장공간(LittleFS)을 쓸 수 없습니다. Arduino IDE의 Tools → Partition Scheme을 '
                                       '기본값(8MB with spiffs)으로 두고 펌웨어를 다시 업로드해 주세요.',
                                       'The board storage (LittleFS) is not available. Set Tools → Partition Scheme in '
                                       'Arduino IDE to the default (8MB with spiffs) and upload the firmware again.'))
                if reply == 'ERR FULL':
                    raise ValueError(T('보드 저장공간이 가득 찼습니다. 사진을 몇 장 지우고 다시 올려 주세요.',
                                       'The board storage is full. Delete a few photos and try again.'))
                if reply == 'ERR NOPHOTO':
                    raise ValueError(T('보드에 저장된 사진이 없습니다. 앱에 사진을 먼저 올려 주세요.',
                                       'There are no photos on the board. Add one in the app first.'))
                if reply.startswith('ERR '):
                    raise ValueError(T('보드가 전송을 거부했습니다: ', 'The board refused it: ') + reply)
                if reply.startswith('OK FACE') and reply != expected:
                    raise ValueError(T(f'보드 펌웨어가 이전 버전({reply[3:]})입니다. 설정 → 보드에서 펌웨어 업데이트를 한 번 해 주세요.',
                                       f'The board has older firmware ({reply[3:]}). Update it once in Settings → Board.'))
                if reply == expected or (expected.endswith(':') and reply.startswith(expected)):
                    return reply
            readable, _, _ = select.select([self.fd], [], [], 0.1)
            if readable:
                chunk = os.read(self.fd, 4096)
                if not chunk:
                    raise OSError(T('USB 연결이 끊어졌습니다.', 'The USB connection was lost.'))
                self.buffer = (self.buffer + chunk)[-8192:]
        raise TimeoutError(T(f'얼굴 엔진({face_modes.PROTOCOL}) 응답이 없습니다. 펌웨어를 업데이트하고 Serial Monitor를 닫아 주세요.',
                             f'No answer from the face engine ({face_modes.PROTOCOL}). Update the firmware and close the Serial Monitor.'))

    def connect(self, port):
        if port not in ports():
            raise ValueError(T('사용 가능한 USB 포트를 선택해 주세요.', 'Choose an available USB port.'))
        self.close()
        fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        self.fd = fd
        try:
            # Exclusive access avoids two copies of this controller using one port.
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if hasattr(termios, 'TIOCEXCL'):
                fcntl.ioctl(fd, termios.TIOCEXCL)
            attrs = termios.tcgetattr(fd)
            attrs[0] = attrs[1] = attrs[3] = 0
            attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
            attrs[4] = attrs[5] = termios.B115200
            attrs[6][termios.VMIN] = 0
            attrs[6][termios.VTIME] = 0
            termios.tcsetattr(fd, termios.TCSANOW, attrs)
            time.sleep(1.8)  # USB boards may reboot when the serial port opens.
            termios.tcflush(fd, termios.TCIOFLUSH)
            self.buffer = b''
            self.port = port
            self.exchange('HELLO', 'OK ' + face_modes.PROTOCOL)
            self.prepare()
            self.message = T('보드 연결 완료', 'Board connected')
        except Exception:
            self.close()
            raise

    def flash_firmware(self, port=None):
        """Compile ESP32_Display.ino, upload it and connect again (USB is released meanwhile)."""
        port = port or self.port or (ports()[0] if ports() else None)
        if not port:
            raise ValueError(T('ESP32가 USB로 연결되어 있지 않습니다.', 'No ESP32 is connected over USB.'))
        self.close()
        self.flashing = True
        try:
            importlib.reload(flasher)   # pick up flasher.py fixes without restarting the app
            report = flasher.flash(port, progress=lambda text: setattr(self, 'message', text))
        except flasher.FlashError as exc:
            raise ValueError(str(exc))
        finally:
            self.flashing = False
        # The board restarts after the upload; its port can take a moment to come back.
        deadline = time.monotonic() + 20
        while True:
            try:
                self.connect(port if port in ports() else ports()[0])
                break
            except (OSError, ValueError, TimeoutError, IndexError):
                if time.monotonic() > deadline:
                    self.message = report + T(' 다시 연결은 실패했어요. 다시 연결을 눌러 주세요.', ' Reconnecting failed; press Reconnect.')
                    return self.message
                time.sleep(1)
        self.message = report
        return report

    def sync_time(self):
        self.exchange(datetime.datetime.now().strftime('TIME:%H:%M:%S'), 'OK TIME')

    def prepare(self):
        """Run on every connect: clock time (the screen saver may show the clock), the
        sleepy/sleeping faces and saver settings, the photo list, and a running timer
        (the board may have restarted when the port opened)."""
        self.sync_time()
        for mood in face_modes.idle_moods():
            reply = self.exchange(f"SUM:{mood['slot']}", 'OK SUM:')
            if reply != f'OK SUM:{face_modes.checksum(mood)}':
                for command, expected in face_modes.commands(mood, play=False):
                    self.exchange(command, expected)
        settings = face_modes.load_settings()
        self.exchange(*face_modes.saver_command(settings['saver']))
        self.exchange(*face_modes.style_command(settings['mono']))
        self.refresh_photos()
        timer = settings['timer']
        if timer:
            left = int(round(timer['end'] - time.time()))
            if 0 < left <= timer['total']:
                self.exchange(*face_modes.timer_command(left, timer['total'], timer['color']))
            else:
                face_modes.save_settings(timer=None)

    def start_timer(self, seconds, color='blue'):
        command = face_modes.timer_command(seconds, seconds, color)  # validate first
        if self.fd is not None:       # without a board the timer still shows in the menu bar
            self.exchange(*command)
        face_modes.save_settings(timer=None if seconds == 0 else dict(end=time.time() + seconds, total=seconds, color=color))
        if seconds:
            self.message = T(f'{face_modes.duration_text(seconds)} 타이머 시작', f'{face_modes.duration_text(seconds)} timer started')
        else:
            self.message = T('타이머를 취소했습니다.', 'Timer canceled.')

    def resync(self):
        """Drop replies and bytes left over from a failed transfer."""
        time.sleep(0.4)   # the board discards input until the line is quiet
        termios.tcflush(self.fd, termios.TCIOFLUSH)
        self.buffer = b''

    def refresh_photos(self):
        self.photos, self.current_photo = face_modes.parse_photo_list(self.exchange('PHOTO:LIST', 'OK LIST:'))

    def upload_photo(self, data, pid=None, attempts=3):
        """Store a new photo in the first free place, or replace photo <pid>."""
        data = face_modes.check_photo(data)
        self.refresh_photos()
        if pid is None:
            free = [i for i in range(face_modes.MAX_PHOTOS) if i not in self.photos]
            if not free:
                raise ValueError(T(f'사진은 {face_modes.MAX_PHOTOS}장까지 저장돼요. 몇 장 지우고 다시 올려 주세요.',
                                   f'The board holds up to {face_modes.MAX_PHOTOS} photos. Delete a few and try again.'))
            pid = free[0]
        elif type(pid) is not int or not 0 <= pid < face_modes.MAX_PHOTOS:
            raise ValueError('사진 번호가 올바르지 않습니다.')
        for attempt in range(attempts):
            try:
                self.exchange(f'PHOTO:BEGIN:{pid}:{len(data)}', 'OK PHOTO')
                for i in range(0, len(data), face_modes.PHOTO_CHUNK):
                    chunk = data[i:i + face_modes.PHOTO_CHUNK]
                    self.exchange(f'PHOTO:DATA:{len(chunk)}', 'OK DATA', chunk)
                self.exchange(f'PHOTO:END:{face_modes.photo_checksum(data)}', 'OK PHOTO')
                break
            except (ValueError, TimeoutError) as exc:
                # Bytes lost on the USB line are retried; storage errors (ERR FS) are not.
                lost = isinstance(exc, TimeoutError) or 'ERR DATA' in str(exc)
                if not lost:
                    raise
                if attempt == attempts - 1:
                    raise ValueError(T('사진 전송 중 데이터가 깨졌습니다. 다시 올려 주세요. 계속되면 펌웨어를 다시 업로드해 주세요.',
                                       'The photo got corrupted on the way. Try again; if it keeps happening, update the firmware.'))
                self.resync()
        try:
            face_modes.PHOTO_DIR.mkdir(parents=True, exist_ok=True)
            face_modes.photo_copy(pid).write_bytes(data)
        except OSError:
            pass   # thumbnail copy only
        self.refresh_photos()
        self.mode, self.emotion, self.screen = 'PHOTO', '', 'photo'
        self.message = T(f'사진을 띄웠습니다 ({len(self.photos)}/{face_modes.MAX_PHOTOS}장 저장).',
                         f'Photo shown ({len(self.photos)}/{face_modes.MAX_PHOTOS} stored).')

    def show_photo(self, pid=None):
        if pid is None:
            self.exchange('PHOTO:SHOW', 'OK PHOTO')
        else:
            if type(pid) is not int or not 0 <= pid < face_modes.MAX_PHOTOS:
                raise ValueError('사진 번호가 올바르지 않습니다.')
            self.exchange(f'PHOTO:SHOW:{pid}', 'OK PHOTO')
        self.refresh_photos()
        self.mode, self.emotion, self.screen = 'PHOTO', '', 'photo'
        self.message = T('사진을 띄웠습니다.', 'Photo shown.')

    def delete_photo(self, pid):
        if type(pid) is not int or not 0 <= pid < face_modes.MAX_PHOTOS:
            raise ValueError('사진 번호가 올바르지 않습니다.')
        self.exchange(f'PHOTO:DEL:{pid}', 'OK PHOTO')
        try:
            face_modes.photo_copy(pid).unlink()
        except OSError:
            pass
        self.refresh_photos()
        self.message = T('사진을 지웠습니다.', 'Photo deleted.')

    def set_saver(self, saver):
        saver = face_modes.validate_saver(saver)
        if self.fd is not None:       # otherwise sent when a board connects (prepare)
            self.exchange(*face_modes.saver_command(saver))
        face_modes.save_settings(saver=saver)
        self.message = T('대기 화면 설정을 저장했습니다.', 'Screen saver saved.')

    def set_style(self, mono):
        command = face_modes.style_command(mono)   # validate first
        if self.fd is not None:       # otherwise sent when a board connects (prepare)
            self.exchange(*command)
        face_modes.save_settings(mono=mono)
        self.message = T('흑백 모드를 켰습니다.', 'Monochrome on.') if mono else T('흑백 모드를 껐습니다.', 'Monochrome off.')

    def set_mode(self, mode, manual=None):
        if mode == 'FIRE':
            if self.fd is not None:
                self.exchange('FIRE', 'OK FIRE')
            self.mode, self.emotion, self.screen = 'FIRE', '', 'fire'
            self.message = T('모닥불을 피웠습니다.', 'Campfire lit.')
            return
        if mode != 'CLOCK':
            raise ValueError(T('알 수 없는 화면입니다.', 'Unknown screen.'))
        try:
            dt = datetime.datetime.strptime(manual, '%H:%M:%S') if manual else datetime.datetime.now()
        except (ValueError, TypeError):
            raise ValueError(T('시간은 00:00:00 ~ 23:59:59로 입력해 주세요.', 'Enter a time from 00:00:00 to 23:59:59.'))
        if self.fd is not None:
            self.exchange(dt.strftime('TIME:%H:%M:%S'), 'OK TIME')
            self.exchange('CLOCK', 'OK CLOCK')
        self.mode = 'CLOCK'
        self.emotion = ''
        self.screen = 'clock'
        self.message = T('시계를 설정했습니다.', 'Clock shown.')

    def upload(self, mode, owner='user'):
        mode = face_modes.validate(mode)
        owner_line = face_modes.owner_command(owner)  # validate before touching the board
        for command, expected in face_modes.commands(mode):
            self.exchange(command, expected)
        # Sent after PLAY so the new face is already showing while the ring color sweeps in.
        self.exchange(*owner_line)
        self.owner = owner
        self.mode = mode['name']
        self.message = mode['name'] + T(' 재생 중', ' playing')

    def show_emotion(self, preset, owner='user', record=True):
        """Show a mood: on the board when one is connected, and always in the menu bar."""
        face_modes.owner_command(owner)   # validate
        if self.fd is None and ports():
            try:
                self.connect(ports()[0])
            except (OSError, ValueError, TimeoutError):
                self.close()          # no usable board: menu bar only
        if self.fd is not None:
            try:
                self.upload(preset, owner)
            except OSError:
                self.close()
        self.owner, self.emotion, self.screen, self.changed = owner, preset['id'], 'face', time.time()
        if record:
            history.record(owner, preset['id'])
        self.mode = preset['name']
        self.message = preset['name'] + (T(' 재생 중', ' playing') if self.fd is not None
                                          else T(' · 보드 없이 메뉴바에 표시 중', ' · in the menu bar (no board)'))

    def expire_working(self, now=None, limit=WORKING_LIMIT):
        """An AI left a working mood (thinking, processing, ...) on for `limit` seconds: it
        probably forgot its closing set_expression, so go back to calm. Not logged."""
        now = time.time() if now is None else now
        if self.screen != 'face' or self.emotion not in face_modes.WORKING or self.owner == 'user' \
                or now - self.changed < limit:
            return False
        calm = next(m for m in face_modes.emotions() if m['id'] == 'calm')
        changed = self.changed
        self.show_emotion(calm, self.owner, record=False)
        self.changed = changed   # the screen saver keeps counting from the AI's last change
        return True

    def view(self, now=None):
        """What the menu bar face should show now (mirrors the board, screen saver included)."""
        now = time.time() if now is None else now
        settings = face_modes.load_settings()
        saver, timer = settings['saver'], settings['timer']
        names = {m['id']: m['name'] for m in face_modes.emotions()}
        kind, emotion = self.screen, self.emotion or 'sleeping'
        photo, clock = -1, False
        if kind == 'photo':
            photo = self.current_photo
        if kind == 'face' and saver['type'] != 'off':
            changed = self.changed
            if timer and timer['end'] <= now:
                changed = max(changed, timer['end'])   # the alarm woke the face, as on the board
            idle, after = now - changed, saver['after'] * 60
            if idle >= after:
                # Menu bar: the same saver as the board. Photos come from the Mac copies of
                # the board's pictures; with none, the sleeping face stands in (as on the board).
                stored = self.photo_ids()
                if saver['type'] in ('clock', 'fire'):
                    kind = saver['type']
                elif saver['type'] in ('photo', 'slideshow') and stored:
                    kind, clock = 'photo', saver['clock']
                    if saver['type'] == 'slideshow':
                        photo = stored[int((idle - after) // saver['slide']) % len(stored)]
                    else:
                        photo = self.current_photo if self.current_photo in stored else stored[0]
                else:
                    emotion = 'sleeping' if saver['type'] != 'sleep' or idle >= 2 * after else 'sleepy'
        left = max(0, int(round(timer['end'] - now))) if timer else 0
        if kind == 'photo' and photo not in self.photo_ids():
            kind = 'face'
        kind = kind if kind in ('face', 'clock', 'fire', 'photo') else 'face'
        try:
            photo_v = int(face_modes.photo_copy(photo).stat().st_mtime) if kind == 'photo' else 0
        except OSError:
            photo_v = 0
        return dict(kind=kind, photo=photo if kind == 'photo' else -1, photo_v=photo_v, clock=clock, mono=settings['mono'],
                    emotion=emotion if kind == 'face' else '',
                    name={'clock': T('시계', 'Clock'), 'fire': T('모닥불', 'Campfire'), 'photo': T('사진', 'Photo')}.get(kind)
                    or names.get(emotion, emotion),
                    owner=self.owner or 'user', board=self.fd is not None,
                    timer=dict(left=left, total=timer['total'], color=timer['color']) if left else None)

    def status(self):
        """Like state(), for the settings window: read-only, so it needs no lock and
        answers even during a firmware upload."""
        available = ports()
        settings = face_modes.load_settings()
        timer = settings['timer']
        left = max(0, int(round(timer['end'] - time.time()))) if timer else 0
        busy = not self.lock.acquire(blocking=False)
        if not busy:
            self.lock.release()
        return dict(ports=available, connected=self.fd is not None and self.port in available,
                    port=self.port, message=self.message, busy=busy, flashing=self.flashing,
                    paused=self.paused, saver=settings['saver'], mono=settings['mono'], photos=list(self.photos),
                    current_photo=self.current_photo, owner=self.owner or 'user',
                    timer=dict(left=left, total=timer['total'], color=timer['color']) if left else None)

    def photo_ids(self):
        """Board photos with a copy on this Mac (the board's list when connected)."""
        ids = self.photos if self.fd is not None else range(face_modes.MAX_PHOTOS)
        return [i for i in ids if face_modes.photo_copy(i).is_file()]

    def state(self):
        available = ports()
        if self.fd is not None and self.port not in available:
            self.close()
            self.message = T('USB 연결이 끊어졌습니다 · 표정은 메뉴바 얼굴에 계속 표시돼요.',
                             'USB disconnected. The face keeps showing in the menu bar.')
        settings = face_modes.load_settings()
        timer = settings['timer']
        left = max(0, int(round(timer['end'] - time.time()))) if timer else 0
        return dict(ports=available, connected=self.fd is not None, port=self.port,
                    mode=self.mode, emotion=self.emotion, owner=self.owner, message=self.message,
                    saver=settings['saver'], photos=self.photos, current_photo=self.current_photo,
                    timer=dict(left=left, total=timer['total'], color=timer['color']) if left else None)
