"""The ESP32 board over USB serial (FACE7 protocol) plus what the face shows when no
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
from . import moods as face_modes


def ports():
    return sorted(set(glob.glob('/dev/cu.usbmodem*') +
                      glob.glob('/dev/cu.usbserial*') + glob.glob('/dev/cu.wchusbserial*') +
                      glob.glob('/dev/cu.SLAB_USBtoUART*')))


class Device:
    def __init__(self, expect_ack=True):
        # FACE7 requires acknowledgments; older firmware must be updated once.
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
        self.message = '보드 없음 · 표정은 메뉴바 얼굴에 표시돼요. 보드를 꽂으면 자동으로 연결해요.'
        self.lock = threading.RLock()
        self.buffer = b''

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
            raise ValueError('먼저 ESP32에 연결해 주세요.')
        packet = (command + '\n').encode('ascii') + payload   # raw bytes follow the line
        deadline = time.monotonic() + 3
        while packet:
            if time.monotonic() > deadline:
                raise TimeoutError('명령 전송 시간이 초과되었습니다.')
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
                    raise ValueError('보드 저장공간(LittleFS)을 쓸 수 없습니다. Arduino IDE의 Tools → Partition Scheme을 '
                                     '기본값(8MB with spiffs)으로 두고 펌웨어를 다시 업로드해 주세요.')
                if reply == 'ERR FULL':
                    raise ValueError('보드 저장공간이 가득 찼습니다. 사진을 몇 장 지우고 다시 올려 주세요.')
                if reply == 'ERR NOPHOTO':
                    raise ValueError('보드에 저장된 사진이 없습니다. 앱에 사진을 먼저 올려 주세요.')
                if reply.startswith('ERR '):
                    raise ValueError('보드가 전송을 거부했습니다: ' + reply)
                if reply.startswith('OK FACE') and reply != expected:
                    raise ValueError('보드 펌웨어가 이전 버전(' + reply[3:] + ')입니다. 새 ESP32_Display.ino를 한 번 업로드해 주세요.')
                if reply == expected or (expected.endswith(':') and reply.startswith(expected)):
                    return reply
            readable, _, _ = select.select([self.fd], [], [], 0.1)
            if readable:
                chunk = os.read(self.fd, 4096)
                if not chunk:
                    raise OSError('USB 연결이 끊어졌습니다.')
                self.buffer = (self.buffer + chunk)[-8192:]
        raise TimeoutError('얼굴 엔진(FACE7) 응답이 없습니다. 새 ESP32_Display.ino를 한 번 업로드하고 Serial Monitor를 닫아 주세요.')

    def connect(self, port):
        if port not in ports():
            raise ValueError('사용 가능한 USB 포트를 선택해 주세요.')
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
            self.exchange('HELLO', 'OK FACE7')
            self.prepare()
            self.message = '얼굴 엔진 연결 완료 · 재생 중인 표정은 유지됩니다.'
        except Exception:
            self.close()
            raise

    def flash_firmware(self, port=None):
        """Compile ESP32_Display.ino, upload it and connect again (USB is released meanwhile)."""
        port = port or self.port or (ports()[0] if ports() else None)
        if not port:
            raise ValueError('ESP32가 USB로 연결되어 있지 않습니다.')
        self.close()
        try:
            importlib.reload(flasher)   # pick up flasher.py fixes without restarting the app
            report = flasher.flash(port)
        except flasher.FlashError as exc:
            raise ValueError(str(exc))
        # The board restarts after the upload; its port can take a moment to come back.
        deadline = time.monotonic() + 20
        while True:
            try:
                self.connect(port if port in ports() else ports()[0])
                break
            except (OSError, ValueError, TimeoutError, IndexError):
                if time.monotonic() > deadline:
                    self.message = report + ' 다시 연결은 실패했어요. 다시 연결을 눌러 주세요.'
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
            self.message = face_modes.duration_text(seconds) + ' 타이머 시작'
        else:
            self.message = '타이머를 취소했습니다.'

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
                raise ValueError(f'사진은 {face_modes.MAX_PHOTOS}장까지 저장돼요. 몇 장 지우고 다시 올려 주세요.')
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
                    raise ValueError('사진 전송 중 데이터가 깨졌습니다. 다시 올려 주세요. '
                                     '계속되면 펌웨어(ESP32_Display.ino)를 다시 업로드해 주세요.')
                self.resync()
        try:
            face_modes.PHOTO_DIR.mkdir(parents=True, exist_ok=True)
            face_modes.photo_copy(pid).write_bytes(data)
        except OSError:
            pass   # thumbnail copy only
        self.refresh_photos()
        self.mode, self.emotion, self.screen = 'PHOTO', '', 'photo'
        self.message = f'사진을 띄웠습니다 ({len(self.photos)}/{face_modes.MAX_PHOTOS}장 저장).'

    def show_photo(self, pid=None):
        if pid is None:
            self.exchange('PHOTO:SHOW', 'OK PHOTO')
        else:
            if type(pid) is not int or not 0 <= pid < face_modes.MAX_PHOTOS:
                raise ValueError('사진 번호가 올바르지 않습니다.')
            self.exchange(f'PHOTO:SHOW:{pid}', 'OK PHOTO')
        self.refresh_photos()
        self.mode, self.emotion, self.screen = 'PHOTO', '', 'photo'
        self.message = '사진을 띄웠습니다.'

    def delete_photo(self, pid):
        if type(pid) is not int or not 0 <= pid < face_modes.MAX_PHOTOS:
            raise ValueError('사진 번호가 올바르지 않습니다.')
        self.exchange(f'PHOTO:DEL:{pid}', 'OK PHOTO')
        try:
            face_modes.photo_copy(pid).unlink()
        except OSError:
            pass
        self.refresh_photos()
        self.message = '사진을 지웠습니다.'

    def set_saver(self, saver):
        saver = face_modes.validate_saver(saver)
        if self.fd is not None:       # otherwise sent when a board connects (prepare)
            self.exchange(*face_modes.saver_command(saver))
        face_modes.save_settings(saver=saver)
        self.message = '대기 화면 설정을 저장했습니다.'

    def set_mode(self, mode, manual=None):
        if mode == 'FIRE':
            if self.fd is not None:
                self.exchange('FIRE', 'OK FIRE')
            self.mode, self.emotion, self.screen = 'FIRE', '', 'fire'
            self.message = '모닥불을 피웠습니다.'
            return
        if mode != 'CLOCK':
            raise ValueError('편집기에서 모드를 선택하고 보드에 저장 · 재생을 눌러 주세요.')
        try:
            dt = datetime.datetime.strptime(manual, '%H:%M:%S') if manual else datetime.datetime.now()
        except (ValueError, TypeError):
            raise ValueError('시간은 00:00:00 ~ 23:59:59로 입력해 주세요.')
        if self.fd is not None:
            self.exchange(dt.strftime('TIME:%H:%M:%S'), 'OK TIME')
            self.exchange('CLOCK', 'OK CLOCK')
        self.mode = 'CLOCK'
        self.emotion = ''
        self.screen = 'clock'
        self.message = '시계를 설정했습니다.'

    def upload(self, mode, owner='user'):
        mode = face_modes.validate(mode)
        owner_line = face_modes.owner_command(owner)  # validate before touching the board
        for command, expected in face_modes.commands(mode):
            self.exchange(command, expected)
        # Sent after PLAY so the new face is already showing while the ring color sweeps in.
        self.exchange(*owner_line)
        self.owner = owner
        self.mode = mode['name']
        self.message = mode['name'] + ' 저장 · 재생 완료. 맥 연결을 끊어도 재생됩니다.'

    def show_emotion(self, preset, owner='user'):
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
        self.mode = preset['name']
        self.message = preset['name'] + (' 모드 재생 중 · 표정은 자동으로 변합니다.' if self.fd is not None
                                          else ' · 보드 없이 메뉴바에 표시 중')

    def view(self, now=None):
        """What the menu bar face should show now (mirrors the board, screen saver included)."""
        now = time.time() if now is None else now
        settings = face_modes.load_settings()
        saver, timer = settings['saver'], settings['timer']
        names = {m['id']: m['name'] for m in face_modes.emotions()}
        kind, emotion = self.screen, self.emotion or 'sleeping'
        if kind == 'face' and saver['type'] != 'off':
            changed = self.changed
            if timer and timer['end'] <= now:
                changed = max(changed, timer['end'])   # the alarm woke the face, as on the board
            idle, after = now - changed, saver['after'] * 60
            if idle >= after:
                # Menu bar: clock and campfire as on the board; photo savers are the sleeping face.
                if saver['type'] in ('clock', 'fire'):
                    kind = saver['type']
                else:
                    emotion = 'sleeping' if saver['type'] != 'sleep' or idle >= 2 * after else 'sleepy'
        left = max(0, int(round(timer['end'] - now))) if timer else 0
        kind = kind if kind in ('face', 'clock', 'fire') else 'face'
        return dict(kind=kind,
                    emotion=emotion if kind == 'face' else '',
                    name={'clock': '시계', 'fire': '모닥불'}.get(kind) or names.get(emotion, emotion),
                    owner=self.owner or 'user', board=self.fd is not None,
                    timer=dict(left=left, total=timer['total'], color=timer['color']) if left else None)

    def state(self):
        available = ports()
        if self.fd is not None and self.port not in available:
            self.close()
            self.message = 'USB 연결이 끊어졌습니다 · 표정은 메뉴바 얼굴에 계속 표시돼요.'
        settings = face_modes.load_settings()
        timer = settings['timer']
        left = max(0, int(round(timer['end'] - time.time()))) if timer else 0
        return dict(ports=available, connected=self.fd is not None, port=self.port,
                    mode=self.mode, emotion=self.emotion, owner=self.owner, message=self.message,
                    saver=settings['saver'], photos=self.photos, current_photo=self.current_photo,
                    timer=dict(left=left, total=timer['total'], color=timer['color']) if left else None)
