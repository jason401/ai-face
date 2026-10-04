import copy
import os
import pty
import sys
import tempfile
import threading
import time
import tty
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'core'))
from aiface import moods as face_modes
from aiface.board import Device

class EngineTests(unittest.TestCase):
    def test_defaults_and_validation(self):
        for mode in face_modes.defaults():
            face_modes.validate(mode)
        for key, (lo, hi) in zip(face_modes.FIELDS, face_modes.LIMITS):
            for invalid in (lo-1, hi+1, True, 2.5):
                mode=copy.deepcopy(face_modes.defaults()[0])
                mode['frames'][0][key]=invalid
                with self.assertRaises(ValueError): face_modes.validate(mode)

    def test_atomic_local_save_and_reload(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(face_modes,'PATH',Path(tmp)/'modes.json'):
            mode=face_modes.defaults()[0];mode['name']='새로운 기분'
            face_modes.save(mode)
            self.assertEqual(face_modes.load()[0]['name'],'새로운 기분')
            mode['frames']=[]
            with self.assertRaises(ValueError): face_modes.save(mode)
            self.assertEqual(face_modes.load()[0]['name'],'새로운 기분')

    def serial_case(self, reject=False, preset=None):
        master,slave=pty.openpty();tty.setraw(slave)
        device=Device();device.fd=slave
        mode=preset or face_modes.defaults()[0]
        packets=list(face_modes.commands(mode))+[face_modes.owner_command('user')];seen=[]
        def board():
            buf=b''
            for expected,reply in packets:
                while b'\n' not in buf: buf+=os.read(master,4096)
                line,buf=buf.split(b'\n',1);seen.append(line.decode())
                if reject and line.startswith(b'FRAME:'):
                    os.write(master,b'ERR FRAME\r\n');return
                # Exercise split acknowledgments.
                response=(reply+'\r\n').encode()
                os.write(master,response[:3]);os.write(master,response[3:])
        worker=threading.Thread(target=board,daemon=True);worker.start()
        try:
            if reject:
                with self.assertRaises(ValueError): device.upload(mode)
                self.assertNotIn('COMMIT',seen)
                self.assertEqual(device.mode,'')
            else:
                device.upload(mode)
                self.assertEqual(seen,[cmd for cmd,_ in packets])
                self.assertEqual(device.mode,mode['name'])
                self.assertEqual(device.owner,'user')
        finally:
            device.close();worker.join(1);os.close(master)

    def test_emotion_catalog(self):
        import json
        moods=face_modes.emotions()
        self.assertEqual(len(moods),64)
        self.assertEqual(len({m['id'] for m in moods}),64)
        self.assertEqual(len({m['name'] for m in moods}),64)
        self.assertEqual(len({json.dumps(m['frames'],sort_keys=True) for m in moods}),64)
        # Seven dedicated slots, "sleeping" in slot 9 for idling; every other mood shares slot 8.
        self.assertEqual(sorted(m['slot'] for m in moods if m['slot']<7),list(range(7)))
        self.assertEqual([m['id'] for m in moods if m['slot']==face_modes.SLEEPING_SLOT],['sleeping'])
        self.assertEqual([m['id'] for m in moods if m['slot']==face_modes.SLEEPY_SLOT],['sleepy'])
        for m in moods:
            with self.subTest(emotion=m['id']):
                face_modes.validate(m)
                self.assertTrue(m['icon'])
                self.assertTrue(m['group'])
                self.serial_case(preset=m)

    def test_face2_modes_still_load(self):
        old={k:v for k,v in face_modes.defaults()[0]['frames'][0].items() if k not in face_modes.OPTIONAL}
        mode=face_modes.validate(dict(slot=0,name='old',frames=[old]))
        self.assertEqual(len(mode['frames'][0]),16)
        self.assertEqual(mode['frames'][0]['eyes'],0)

    def test_frame_line_fits_firmware_buffer(self):
        for m in face_modes.emotions():
            for command,_ in face_modes.commands(m):
                self.assertLess(len(command),191)
                if command.startswith('FRAME:'):
                    self.assertEqual(command.count(','),15)

    def test_old_firmware_is_reported(self):
        master,slave=pty.openpty();tty.setraw(slave)
        device=Device();device.fd=slave
        def board():
            os.read(master,64);os.write(master,b'OK FACE2\r\n')
        worker=threading.Thread(target=board,daemon=True);worker.start()
        try:
            with self.assertRaises(ValueError) as ctx: device.exchange('HELLO','OK FACE7')
            self.assertIn('이전 버전',str(ctx.exception))
        finally:
            device.close();worker.join(1);os.close(master)

    def test_owner_commands(self):
        self.assertEqual(face_modes.owner_command('user'),('OWNER:0','OK OWNER'))
        self.assertEqual(face_modes.owner_command('claude'),('OWNER:1','OK OWNER'))
        self.assertEqual(face_modes.owner_command('gpt'),('OWNER:2','OK OWNER'))
        with self.assertRaises(ValueError): face_modes.owner_command('someone')

    def test_firmware_matches_protocol(self):
        ino=(Path(__file__).resolve().parents[1]/'firmware'/'ESP32_Display'/'ESP32_Display.ino').read_text()
        self.assertIn('"OK FACE7"',ino); self.assertIn('"OK OWNER"',ino)
        for reply in ('"OK TIMER"','"OK SAVER"','"ERR FULL"','"OK LIST:','"OK SUM:','"OK TIME"','"OK PHOTO"','"OK DATA"','"ERR FS"','"ERR NOPHOTO"'): self.assertIn(reply,ino)
        self.assertIn('PHOTO_BYTES=240*240*2, PHOTO_CHUNK=%d'%face_modes.PHOTO_CHUNK,ino)
        self.assertIn('MAX_PHOTOS=%d;'%face_modes.MAX_PHOTOS,ino)
        self.assertIn('enum { SV_SLEEP, SV_CLOCK, SV_PHOTO, SV_SLIDES, SV_OFF, SV_FIRE, SV_COUNT };',ino)
        self.assertEqual(face_modes.SAVER_TYPES,('sleep','clock','photo','slideshow','off','fire'))
        self.assertIn('"OK FIRE"',ino)
        self.assertIn('SLEEPY_SLOT=%d, SLEEPING_SLOT=%d'%(face_modes.SLEEPY_SLOT,face_modes.SLEEPING_SLOT),ino)
        self.assertIn('const int SLOTS=%d;'%face_modes.SLOTS,ino)
        self.assertIn('{0xD9,0x77,0x57}',ino); self.assertIn('{0x10,0xA3,0x7F}',ino)

    def test_timer_and_saver_commands(self):
        self.assertEqual(face_modes.timer_command(1500,1500,'red'),('TIMER:1500:1500:4','OK TIMER'))
        self.assertEqual(face_modes.timer_command(0,0)[0],'TIMER:0:0:2')
        for bad in ((10,5,'blue'),(-1,5,'blue'),(5,86401,'blue'),(5,5,'navy'),(True,5,'blue')):
            with self.assertRaises(ValueError): face_modes.timer_command(*bad)
        self.assertEqual(face_modes.saver_command(face_modes.SAVER_DEFAULT),('SAVER:600:0:0:60','OK SAVER'))
        self.assertEqual(face_modes.saver_command(dict(after=2,type='slideshow',clock=True,slide=30))[0],'SAVER:120:3:1:30')
        for bad in (dict(after=0),dict(after=1441),dict(after=1.5),dict(type='movie'),dict(clock=1),dict(slide=2)):
            with self.assertRaises(ValueError): face_modes.validate_saver(bad)
        self.assertEqual(face_modes.parse_photo_list('OK LIST:145:7'),([0,4,7],7))
        self.assertEqual(face_modes.duration_text(1500),'25분')
        self.assertEqual(face_modes.duration_text(3630),'1시간 30초')

    def test_settings_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(face_modes,'SETTINGS',Path(tmp)/'s'/'settings.json'):
            self.assertEqual(face_modes.load_settings(),dict(saver=face_modes.SAVER_DEFAULT,timer=None))
            # FACE5/6 idle settings carry over their first delay
            face_modes.SETTINGS.parent.mkdir(parents=True)
            face_modes.SETTINGS.write_text('{"idle": {"sleepy": 3, "sleeping": 6, "clock": 9}}')
            self.assertEqual(face_modes.load_settings()['saver']['after'],3)
            face_modes.save_settings(saver=dict(after=5,type='photo',clock=True,slide=60))
            face_modes.save_settings(timer=dict(end=123.0,total=60,color='green'))
            s=face_modes.load_settings()
            self.assertEqual(s['saver'],dict(after=5,type='photo',clock=True,slide=60))
            self.assertEqual(s['timer']['color'],'green')
            face_modes.SETTINGS.write_text('{broken')
            self.assertEqual(face_modes.load_settings()['timer'],None)

    def fake_board(self, master, sums, seen):
        """Answer like FACE7 firmware until the port closes."""
        def run():
            buf=b''
            while True:
                try: chunk=os.read(master,4096)
                except OSError: return
                if not chunk: return
                buf+=chunk
                while b'\n' in buf:
                    line,buf=buf.split(b'\n',1);text=line.decode();seen.append(text)
                    key=text.split(':')[0]
                    reply='OK SUM:%d'%sums.get(int(text[4:]),0) if key=='SUM' else 'OK LIST:0:-1' if text=='PHOTO:LIST' else {'HELLO':'OK FACE7'}.get(key,'OK '+key)
                    os.write(master,(reply+'\r\n').encode())
        worker=threading.Thread(target=run,daemon=True);worker.start();return worker

    def test_prepare_sends_idle_faces_only_when_changed(self):
        sleepy,sleeping=face_modes.idle_moods()
        with tempfile.TemporaryDirectory() as tmp, patch.object(face_modes,'SETTINGS',Path(tmp)/'settings.json'):
            face_modes.save_settings(timer=dict(end=time.time()+90,total=120,color='red'))
            master,slave=pty.openpty();tty.setraw(slave);seen=[]
            # Slot 4 (sleepy) already matches, slot 9 (sleeping) is missing.
            worker=self.fake_board(master,{3:face_modes.checksum(sleepy)},seen)
            device=Device();device.fd=slave
            try: device.prepare()
            finally: device.close();os.close(master);worker.join(1)
        self.assertTrue(seen[0].startswith('TIME:'))
        self.assertEqual([x for x in seen if x.startswith('BEGIN')],['BEGIN:8:%d'%len(sleeping['frames'])])
        self.assertFalse(any(x.startswith('PLAY') for x in seen))   # stored only, not shown
        self.assertIn('SAVER:600:0:0:60',seen)
        self.assertIn('PHOTO:LIST',seen)
        timer=[x for x in seen if x.startswith('TIMER')]
        self.assertEqual(len(timer),1)
        left=int(timer[0].split(':')[1]);self.assertTrue(85<=left<=90,timer)
        self.assertTrue(timer[0].endswith(':120:4'))

    def test_expired_timer_is_forgotten(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(face_modes,'SETTINGS',Path(tmp)/'settings.json'):
            face_modes.save_settings(timer=dict(end=time.time()-5,total=60,color='blue'))
            master,slave=pty.openpty();tty.setraw(slave);seen=[]
            worker=self.fake_board(master,{},seen)
            device=Device();device.fd=slave;device.port=os.ttyname(slave)
            try:
                device.prepare()
                self.assertIsNone(face_modes.load_settings()['timer'])
                device.start_timer(300,'green')
                self.assertEqual(face_modes.load_settings()['timer']['total'],300)
                with patch('aiface.board.ports',return_value=[os.ttyname(slave)]):
                    self.assertEqual(device.state()['timer']['left'],300)
                device.start_timer(0)
                self.assertIsNone(face_modes.load_settings()['timer'])
            finally: device.close();os.close(master);worker.join(1)
        self.assertFalse(any(x.startswith('TIMER:') and not x.startswith('TIMER:0') and x!='TIMER:300:300:5' for x in seen),seen)
        self.assertEqual(seen[-1],'TIMER:0:0:2')

    def photo_board(self, master, store, fail_at=None, corrupt_first=False, log=None):
        """FACE7 photo store: a PHOTO:DATA:<n> line is followed by n raw bytes."""
        state=dict(current=-1,attempts=0)
        def run():
            buf=b'';data=bytearray();pid=None
            while True:
                try: chunk=os.read(master,65536)
                except OSError: return
                if not chunk: return
                buf+=chunk
                while b'\n' in buf:
                    line,rest=buf.split(b'\n',1);text=line.decode()
                    if text.startswith('PHOTO:DATA:'):
                        n=int(text[11:])
                        if len(rest)<n: break        # wait for the rest of the bytes
                        data+=rest[:n];buf=rest[n:]
                        reply='ERR FS' if fail_at is not None and len(data)>fail_at else 'OK DATA'
                    else:
                        buf=rest
                        if log is not None: log.append(text)
                        if text=='PHOTO:LIST':
                            reply='OK LIST:%d:%d'%(sum(1<<i for i in store),state['current'])
                        elif text.startswith('PHOTO:BEGIN:'):
                            pid=int(text.split(':')[2]);data=bytearray();reply='OK PHOTO'
                        elif text.startswith('PHOTO:END:'):
                            state['attempts']+=1
                            if corrupt_first and state['attempts']==1: data[5]^=1   # a byte lost on the wire
                            ok=int(text[10:])==face_modes.photo_checksum(data)
                            if ok: store[pid]=bytes(data);state['current']=pid
                            reply='OK PHOTO' if ok else 'ERR DATA'
                        elif text.startswith('PHOTO:DEL:'):
                            store.pop(int(text[10:]),None);reply='OK PHOTO'
                        elif text.startswith('PHOTO:SHOW:'):
                            i=int(text[11:]);reply='OK PHOTO' if i in store else 'ERR NOPHOTO'
                            if i in store: state['current']=i
                        else: reply='OK PHOTO'
                    os.write(master,(reply+'\r\n').encode())
        worker=threading.Thread(target=run,daemon=True);worker.start();return worker,state

    def test_photo_upload_gallery(self):
        # Bytes that look like line breaks must pass through untouched.
        photo=bytes((i*7+(i>>9))&255 if i%5 else 10 for i in range(face_modes.PHOTO_BYTES))
        other=bytes(reversed(photo))
        with tempfile.TemporaryDirectory() as tmp, patch.object(face_modes,'PHOTO_DIR',Path(tmp)/'photos'), \
                patch.object(face_modes,'LEGACY_PHOTO',Path(tmp)/'photo.rgb565'):
            master,slave=pty.openpty();tty.setraw(slave);store={1:b'x'};log=[]
            worker,state=self.photo_board(master,store,log=log)
            device=Device();device.fd=slave
            try:
                device.upload_photo(photo)                       # first free place: 0
                self.assertEqual(store[0],photo); self.assertEqual(device.photos,[0,1]); self.assertEqual(device.current_photo,0)
                self.assertEqual(device.mode,'PHOTO')
                self.assertEqual(face_modes.local_photo(0),photo)
                device.upload_photo(other)                       # next free: 2
                self.assertEqual(sorted(store),[0,1,2])
                device.upload_photo(photo,2)                     # replace (fit changed)
                self.assertEqual(store[2],photo); self.assertEqual(sorted(store),[0,1,2])
                device.show_photo(1); self.assertEqual(device.current_photo,1)
                device.delete_photo(2); self.assertEqual(device.photos,[0,1]); self.assertIsNone(face_modes.local_photo(2))
                with self.assertRaises(ValueError): device.show_photo(5)
                with self.assertRaises(ValueError): device.upload_photo(photo[:100])
                for i in range(2,10): store[i]=b'x'
                with self.assertRaises(ValueError) as ctx: device.upload_photo(photo)
                self.assertIn('10장',str(ctx.exception))
            finally: device.close();os.close(master);worker.join(1)
        self.assertIn('PHOTO:BEGIN:2:115200',log)

    def test_legacy_photo_becomes_photo_0(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(face_modes,'PHOTO_DIR',Path(tmp)/'photos'), \
                patch.object(face_modes,'LEGACY_PHOTO',Path(tmp)/'photo.rgb565'):
            face_modes.LEGACY_PHOTO.write_bytes(bytes(face_modes.PHOTO_BYTES))
            self.assertEqual(face_modes.local_photo(0),bytes(face_modes.PHOTO_BYTES))
            self.assertFalse(face_modes.LEGACY_PHOTO.exists())
            self.assertIsNone(face_modes.local_photo(3)); self.assertIsNone(face_modes.local_photo(True))

    def test_photo_retries_after_lost_bytes(self):
        photo=bytes(range(256))*(face_modes.PHOTO_BYTES//256)
        with tempfile.TemporaryDirectory() as tmp, patch.object(face_modes,'PHOTO_DIR',Path(tmp)/'p'):
            master,slave=pty.openpty();tty.setraw(slave);store={}
            worker,state=self.photo_board(master,store,corrupt_first=True)
            device=Device();device.fd=slave
            try: device.upload_photo(photo)
            finally: device.close();os.close(master);worker.join(1)
        self.assertEqual(state['attempts'],2)
        self.assertEqual(store[0],photo)

    def test_photo_storage_error_is_explained(self):
        master,slave=pty.openpty();tty.setraw(slave)
        worker,_=self.photo_board(master,{},fail_at=0)
        device=Device();device.fd=slave
        try:
            with self.assertRaises(ValueError) as ctx: device.upload_photo(bytes(face_modes.PHOTO_BYTES))
            self.assertIn('Partition Scheme',str(ctx.exception))
        finally: device.close();os.close(master);worker.join(1)

    def test_transfer_acknowledgments(self): self.serial_case()
    def test_rejected_frame_does_not_commit(self): self.serial_case(True)

if __name__=='__main__': unittest.main()
