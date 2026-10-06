"""Moods and board protocol data: the 71 face animations, validation, settings and the
command lines sent to the ESP32 (firmware protocol FACE8: FACE3 frames + owner ring +
countdown timer ring + photos + screen saver + monochrome style + hand/bulb effects)."""
import json
import os

from . import paths
from .i18n import T, lang

FIELDS = ['move', 'hold', 'left', 'right', 'x', 'y', 'width', 'smile', 'open',
          'brow', 'lift', 'eyes', 'tilt', 'fx', 'color', 'shake']
LIMITS = [(80,5000),(0,10000),(0,100),(0,100),(-15,15),(-10,10),(10,100),(-28,28),(0,30),
          (-10,10),(0,12),(0,9),(-10,10),(0,8191),(0,7),(0,6)]
# FACE3 fields may be missing in modes saved by FACE2; they default to 0.
OPTIONAL = {'brow','lift','eyes','tilt','fx','color','shake'}
PATH = paths.DATA / 'face_modes.json'   # user modes from the old editor

# Eye shapes (eyes)
NORMAL, ARC, CALM, CROSS, HEART, SPIRAL, STAR, DOT, BIG, SQUEEZE = range(10)
# Effect bits (fx)
BLUSH, TEAR, SWEAT, ZZZ, HEARTS, ANGER, QUESTION, EXCLAIM, SPARKLE, NOTE, WAVE, BULB, PRAY = (1 << i for i in range(13))
# HELLO reply of the firmware this code talks to.
PROTOCOL = 'FACE8'
# Face colors (color)
WHITE, PINK, BLUE, YELLOW, RED, GREEN, PURPLE, ORANGE = range(8)
# Who chose the face; the board draws a matching border ring.
# user = picked in the Mac app (white), claude = #D97757 orange, gpt = #10A37F green
OWNERS = ('user', 'claude', 'gpt')
# Board slots: 0-6 dedicated moods, 7 shared by the other moods, 8 = "sleeping" (screen saver).
SLOTS = 9
SLEEPY_SLOT, SLEEPING_SLOT = 3, 8
# Timer ring colors, same order as the firmware PALETTE.
TIMER_COLORS = ('white', 'pink', 'blue', 'yellow', 'red', 'green', 'purple', 'orange')
MAX_SECONDS = 86400
# Shared by the controller app and the MCP server (both may run from different folders).
SETTINGS = paths.SETTINGS
# Screen saver: shown when the face has not changed for <after> minutes.
#   sleep = sleepy face, then asleep after twice the time; clock; photo (the current one);
#   slideshow (every photo in turn, <slide> seconds each); off; fire (pixel-art campfire).
# clock = draw clock hands on top of photos.
SAVER_TYPES = ('sleep', 'clock', 'photo', 'slideshow', 'off', 'fire')
SAVER_DEFAULT = dict(after=10, type='sleep', clock=False, slide=60)
# Photos: 240x240 RGB565, little-endian, row by row (the controller page converts any image).
PHOTO_BYTES = 240 * 240 * 2
PHOTO_CHUNK = 4096
MAX_PHOTOS = 10
PHOTO_DIR = SETTINGS.with_name('photos')          # Mac copies, for the app's thumbnails
LEGACY_PHOTO = SETTINGS.with_name('photo.rgb565')  # FACE6 single photo = board photo 0


def frame(move=400, hold=800, left=100, right=100, x=0, y=0, width=70, smile=18, opening=0,
          brow=0, lift=0, eyes=0, tilt=0, fx=0, color=0, shake=0):
    return dict(zip(FIELDS,[move,hold,left,right,x,y,width,smile,opening,brow,lift,eyes,tilt,fx,color,shake]))


def F(move, hold, l=100, r=100, x=0, y=0, w=70, s=18, o=0, **extra):
    """Compact catalog helper: l/r eye openness, w mouth width, s smile, o mouth opening."""
    return frame(move, hold, l, r, x, y, w, s, o, **extra)


def validate(mode):
    if not isinstance(mode,dict): raise ValueError(T('모드 형식이 올바르지 않습니다.','Invalid mode.'))
    slot=mode.get('slot');name=mode.get('name');frames=mode.get('frames')
    if type(slot) is not int or not 0<=slot<SLOTS: raise ValueError(T('저장 위치는 1~9입니다.','The slot must be 1-9.'))
    if not isinstance(name,str) or not 1<=len(name.strip())<=32: raise ValueError(T('이름을 1~32자로 입력하세요.','The name must be 1-32 characters.'))
    if not isinstance(frames,list) or not 1<=len(frames)<=24: raise ValueError(T('동작은 1~24개로 구성하세요.','A mode has 1-24 frames.'))
    clean=[]
    for f in frames:
        if not isinstance(f,dict): raise ValueError(T('동작 형식이 올바르지 않습니다.','Invalid frame.'))
        row={}
        for key,(lo,hi) in zip(FIELDS,LIMITS):
            value=f.get(key, 0 if key in OPTIONAL else None)
            if type(value) is not int or not lo<=value<=hi: raise ValueError(T(f'{key}: {lo}~{hi} 범위의 정수가 필요합니다.',f'{key}: needs a whole number from {lo} to {hi}.'))
            row[key]=value
        clean.append(row)
    return dict(slot=slot,name=name.strip(),frames=clean)


# ---------------------------------------------------------------------------
# Emotion catalog: 71 moods + auto. Each entry:
# (id, name, icon, group, description, dedicated slot or None, frames)
# The board has 9 slots: the seven most-used moods keep slots 1-7, "sleeping"
# keeps slot 9 (idle stage), and every other mood shares slot 8, replaced
# automatically when selected.
# ---------------------------------------------------------------------------
JOY, LOVE, WONDER, MIND, REST, SAD, TENSE, ANGRY, BODY = (
    '기쁨', '사랑·유대', '놀람·관심', '생각·대화', '평온·휴식', '슬픔', '불안·긴장', '분노·불쾌', '몸 상태')
# Stable group ids (stats, colors) and English group names.
GROUP_IDS = {JOY: 'joy', LOVE: 'love', WONDER: 'wonder', MIND: 'mind', REST: 'rest', SAD: 'sad',
             TENSE: 'tense', ANGRY: 'angry', BODY: 'body', '자동': 'auto'}
GROUP_EN = {'joy': 'Joy', 'love': 'Love & bond', 'wonder': 'Surprise & interest', 'mind': 'Thinking & talking',
            'rest': 'Calm & rest', 'sad': 'Sadness', 'tense': 'Anxiety & tension', 'angry': 'Anger & dislike',
            'body': 'Body', 'auto': 'Auto'}
# Short notes for the AI on moods whose id alone is ambiguous (the MCP tool list shows only
# ids by group, to keep it small).
HINTS = {
    'greeting': 'hello', 'farewell': 'waves goodbye', 'smitten': 'flustered crush',
    'dazed': 'spaced out', 'rueful': 'smiling but oh well', 'sulky': 'hurt, pouting',
    'hopeful': 'fingers crossed', 'cringe': 'secondhand embarrassment',
    'contempt': 'scornful smirk', 'knocked_out': 'X eyes, KO', 'auto': 'cycles several moods',
}

# English names and looks, by mood id.
EN = {
    'happy': ('Happy', 'Smiling and laughing, the odd wink'),
    'excited': ('Excited', 'Big smile, sparkling with excitement'),
    'playful': ('Playful', 'Winks one eye, then the other, with a grin'),
    'laughing': ('Laughing', 'Eyes squeezed shut, laughing out loud'),
    'proud': ('Proud', 'Chin up a little, a pleased smile'),
    'content': ('Content', 'Eyes closed, a relaxed smile'),
    'triumph': ('Triumph', 'Star eyes, cheering big'),
    'singing': ('Humming', 'Eyes closed, humming along to a rhythm'),
    'greeting': ('Hello', 'Raised brows and a wink: nice to see you'),
    'cheering': ('Cheering', 'Determined brows and a big smile: you got this!'),
    'farewell': ('Goodbye', 'Waves a hand with a smile'),
    'affectionate': ('Affectionate', 'A soft smile and a slow blink'),
    'shy': ('Shy', 'Blushing, looking down with a smile'),
    'love': ('Love', 'Heart eyes, beaming love'),
    'smitten': ('Smitten', 'Heart racing, looks away and back again'),
    'grateful': ('Grateful', 'A little bow and a bright smile'),
    'touched': ('Touched', 'Teary eyes and a smile'),
    'sympathy': ('Sympathy', 'Worried brows, slow nods'),
    'pleading': ('Pleading', 'Big shiny eyes, hoping hard'),
    'surprised': ('Surprised', 'Brows jump up, a small open mouth'),
    'curious': ('Curious', 'Looks around, wondering'),
    'awe': ('Awe', 'Sparkling eyes, mouth open in wonder'),
    'eager': ('Eager', 'Bouncing, can hardly wait'),
    'idea': ('Idea', 'Looks up, then a light bulb: excited'),
    'realization': ('Realization', 'A pause, then: got it!'),
    'shocked': ('Shocked', 'Pinpoint eyes, jaw dropped'),
    'confused': ('Confused', 'Mismatched eyes, a crooked mouth and a question mark'),
    'determined': ('Determined', "Focused eyes, lips pressed: let's do this"),
    'serious': ('Serious', 'A flat mouth, brows slightly drawn, calm'),
    'thinking': ('Thinking', 'Looks up, deep in thought'),
    'skeptical': ('Skeptical', 'Narrowed eyes, a twisted mouth'),
    'focused': ('Focused', 'Narrowed eyes fixed on one spot'),
    'listening': ('Listening', 'Nodding along, all ears'),
    'talking': ('Talking', 'Mouth moving, talking'),
    'processing': ('Processing', 'Eyes circling, working it out'),
    'calm': ('Calm', 'Easy blinks and glances'),
    'sleepy': ('Sleepy', 'Drooping eyes and a yawn'),
    'bored': ('Bored', 'Half-open eyes, slowly looking around'),
    'relieved': ('Relieved', 'A big "phew", relaxing'),
    'goodnight': ('Good night', 'Eyes closed, a small smile: sleep well'),
    'sleeping': ('Asleep', 'Eyes closed, sleeping softly'),
    'waking': ('Waking up', 'Groggy eyes, a yawn, then bright'),
    'dazed': ('Dazed', 'Small eyes staring into space'),
    'sad': ('Sad', 'Drooping brows, slow moves'),
    'crying': ('Crying', 'Tears falling, sobbing'),
    'disappointed': ('Disappointed', 'A smile that slowly falls'),
    'lonely': ('Lonely', 'Blue, gazing far away'),
    'rueful': ('Rueful', 'Smiling but tilted, a drop of sweat: oh well'),
    'apologetic': ('Sorry', 'Head down, sweating'),
    'sulky': ('Sulky', 'Turns away with a pout'),
    'exhausted': ('Exhausted', 'Droopy eyes and sweat, no energy left'),
    'afraid': ('Afraid', 'Glancing left and right, shrinking back'),
    'worried': ('Worried', 'Knitted brows, looking down'),
    'nervous': ('Nervous', 'Cold sweat, trembling, an awkward smile'),
    'flustered': ('Flustered', 'Face heating up, eyes wide'),
    'hopeful': ('Fingers crossed', 'Hands together, eyes shut: hoping it works'),
    'awkward': ('Awkward', 'A drop of sweat and a sheepish smile'),
    'terrified': ('Terrified', 'Pale purple, shaking'),
    'cringe': ('Cringe', '> < eyes squeezed shut, shuddering'),
    'angry': ('Angry', 'Frowning brows, lips pressed'),
    'furious': ('Furious', 'Bright red, shaking with rage'),
    'annoyed': ('Annoyed', 'Rolls eyes and sighs'),
    'disgusted': ('Disgusted', 'Squints and turns away'),
    'contempt': ('Contempt', 'One corner of the mouth up, looking down'),
    'jealous': ('Jealous', 'Side-eye and a pout, fuming'),
    'sick': ('Sick', 'Green and queasy'),
    'dizzy': ('Dizzy', 'Spinning spiral eyes'),
    'cold': ('Cold', 'Blue, teeth chattering'),
    'hot': ('Hot', 'Orange face, panting and sweating'),
    'hungry': ('Hungry', 'Big eyes, looking around for food'),
    'knocked_out': ('Knocked out', 'X eyes, stars circling'),
    'auto': ('Auto', 'Calm, curious, happy, playful, love and sleepy in turn'),
}

CATALOG = [
  # ----- 기쁨 -----
  ('happy','행복','☺',JOY,'미소와 웃음, 가끔 윙크',0,[
    F(400,800),F(400,800,x=10),F(100,40,0,0,x=10),F(180,900,x=10),
    F(400,800,w=90,s=26,o=12,eyes=ARC,fx=BLUSH),F(140,220,0,100,s=24),F(400,800,lift=5),F(400,800,x=-10)]),
  ('excited','신남','✦',JOY,'활짝 웃으며 반짝반짝 들떠요',5,[
    F(250,500,w=95,s=26,o=22,lift=7,fx=SPARKLE),F(220,450,55,55,y=-4,w=100,s=28,o=20,lift=8,fx=SPARKLE,shake=1),
    F(250,500,x=10,w=90,s=25,o=16,eyes=STAR,fx=SPARKLE),F(250,500,x=-10,w=90,s=25,o=16,eyes=STAR,fx=SPARKLE),
    F(100,50,0,0,w=90,s=25,lift=6),F(200,1000,w=95,s=25,o=18,eyes=ARC,lift=7)]),
  ('playful','장난','😜',JOY,'번갈아 윙크하며 씨익 웃어요',6,[
    F(450,800,x=12,s=22,tilt=5),F(160,350,0,100,x=12,s=26,tilt=7,lift=5,brow=-3),F(220,900,s=22),
    F(400,800,x=-12,s=24,tilt=-5),F(160,350,100,0,x=-12,s=26,tilt=-7,lift=5,brow=-3),F(350,1200,w=85,s=24,o=8,eyes=ARC)]),
  ('laughing','웃음 터짐','😆',JOY,'눈을 질끈 감고 깔깔 웃어요',None,[
    F(150,120,w=90,s=26,o=28,eyes=SQUEEZE,shake=2),F(120,100,w=88,s=24,o=12,eyes=SQUEEZE,shake=2),
    F(150,120,w=92,s=26,o=28,eyes=SQUEEZE,shake=2),F(120,100,w=88,s=24,o=10,eyes=ARC,shake=2),
    F(150,120,w=90,s=26,o=26,eyes=ARC,shake=1),F(300,800,w=85,s=24,o=8,eyes=ARC,fx=BLUSH)]),
  ('proud','뿌듯함','😌',JOY,'고개를 살짝 들고 흐뭇하게 웃어요',None,[
    F(500,1500,70,70,y=-6,s=20,lift=6,brow=-2),F(400,1200,y=-7,s=22,lift=7,eyes=ARC,fx=SPARKLE),
    F(120,60,0,0,y=-6,s=20,lift=6),F(500,1200,75,75,x=4,y=-5,s=21,lift=6,tilt=3)]),
  ('content','만족','☺︎',JOY,'눈을 감고 편안하게 미소 지어요',None,[
    F(800,2000,w=60,s=14,eyes=CALM),F(600,1200,70,70,w=60,s=14),F(140,80,0,0,w=60,s=14),
    F(700,1800,x=3,w=62,s=16,eyes=CALM,fx=BLUSH)]),
  ('triumph','승리','🏆',JOY,'별빛 눈으로 크게 환호해요',None,[
    F(200,700,y=-6,w=95,s=26,o=20,eyes=STAR,fx=SPARKLE,color=YELLOW),
    F(200,500,y=-8,w=100,s=28,o=26,eyes=ARC,fx=SPARKLE,shake=1,lift=8),
    F(250,600,y=-5,w=90,s=25,o=16,eyes=STAR,fx=SPARKLE,color=YELLOW),F(300,900,y=-4,w=85,s=24,o=8,lift=7)]),
  ('singing','흥얼거림','♪',JOY,'눈을 감고 리듬 타며 흥얼거려요',None,[
    F(400,500,x=-5,w=30,s=6,o=14,eyes=CALM,fx=NOTE),F(400,500,x=5,w=34,s=8,o=8,eyes=CALM,fx=NOTE),
    F(400,500,x=-5,w=28,s=6,o=18,eyes=CALM,fx=NOTE),F(400,500,80,80,x=5,w=36,s=10,o=6,fx=NOTE)]),
  ('greeting','반가움','👋',JOY,'눈썹을 올리고 윙크하며 반겨요',None,[
    F(250,600,lift=8,w=85,s=24,o=14),F(160,400,0,100,lift=8,w=85,s=26,o=8),
    F(200,600,lift=8,w=90,s=26,o=18,eyes=ARC,fx=SPARKLE),F(400,1200,lift=6,w=75,s=20)]),
  ('cheering','응원','📣',JOY,'눈썹에 힘주고 활짝 웃으며 파이팅!',None,[
    F(250,500,y=-3,w=90,s=26,o=18,eyes=ARC,lift=6,brow=-4,fx=SPARKLE),F(200,400,y=2,w=85,s=24,o=10,lift=6,brow=-4,fx=SPARKLE),
    F(250,500,y=-4,w=95,s=26,o=22,eyes=STAR,lift=7,brow=-4,fx=SPARKLE,color=YELLOW),F(200,600,w=85,s=24,o=8,eyes=ARC,lift=6,brow=-3)]),
  ('farewell','배웅','🖐',JOY,'손을 흔들며 웃는 얼굴로 배웅해요',None,[
    F(300,900,w=80,s=24,o=8,lift=6,fx=WAVE),F(160,500,100,0,w=80,s=24,o=6,lift=6,fx=WAVE),
    F(300,1200,w=85,s=24,o=12,eyes=ARC,lift=6,fx=WAVE)]),
  # ----- 사랑·유대 -----
  ('affectionate','다정함','♡',LOVE,'부드러운 미소와 느린 눈인사',None,[
    F(850,1400,65,65,w=75,s=22),F(550,450,w=80,s=24,eyes=ARC,fx=BLUSH),
    F(700,1300,65,65,x=3,w=75,s=22),F(900,1200,75,75,x=-3,w=70,s=20)]),
  ('shy','수줍음','☺',LOVE,'볼이 붉어지고 아래를 보며 웃어요',None,[
    F(700,1100,60,60,x=-10,y=8,w=40,s=12,fx=BLUSH),F(800,700,80,80,y=2,w=45,s=14,fx=BLUSH),
    F(220,500,y=7,w=42,s=17,eyes=ARC,fx=BLUSH),F(650,1500,55,55,x=9,y=8,w=38,s=12,fx=BLUSH)]),
  ('love','사랑','😍',LOVE,'하트 눈으로 사랑을 뿜어요',None,[
    F(300,1400,w=70,s=22,eyes=HEART,fx=HEARTS|BLUSH),F(250,500,y=-3,w=75,s=24,o=8,eyes=HEART,fx=HEARTS|BLUSH,shake=1),
    F(140,80,0,0,w=70,s=22,fx=HEARTS|BLUSH),F(300,1400,x=4,w=70,s=22,eyes=HEART,fx=HEARTS|BLUSH,color=PINK)]),
  ('smitten','설렘','💓',LOVE,'두근두근, 눈을 피했다 다시 봐요',None,[
    F(500,1000,x=-8,y=4,w=40,s=12,eyes=BIG,fx=BLUSH),F(300,500,y=3,w=45,s=16,eyes=ARC,fx=BLUSH|HEARTS),
    F(500,900,x=8,y=4,w=40,s=12,eyes=BIG,fx=BLUSH),F(160,60,0,0,y=4,w=40,s=12,fx=BLUSH)]),
  ('grateful','고마움','🙏',LOVE,'고개 숙여 인사하고 환하게 웃어요',None,[
    F(700,800,w=70,s=22,eyes=ARC),F(800,900,y=9,w=60,s=18,eyes=CALM,brow=3,lift=4),
    F(700,1200,w=70,s=22,eyes=ARC,fx=SPARKLE),F(600,1000,80,80,w=65,s=20)]),
  ('touched','감동','🥹',LOVE,'글썽이는 눈으로 미소 지어요',None,[
    F(800,1400,brow=6,lift=5,w=60,s=14,eyes=BIG,fx=TEAR),F(400,800,brow=6,lift=5,w=65,s=18,eyes=CALM,fx=TEAR),
    F(150,80,0,0,brow=5,lift=5,w=60,s=14,fx=TEAR),F(700,1400,brow=4,lift=5,w=65,s=16,eyes=BIG,fx=TEAR|SPARKLE)]),
  ('sympathy','공감','🤝',LOVE,'걱정 어린 눈썹으로 천천히 끄덕여요',None,[
    F(700,1200,80,80,y=2,w=50,s=4,brow=6,lift=4),F(600,500,70,70,y=8,w=50,s=2,brow=6,lift=4),
    F(600,1000,80,80,y=1,w=52,s=6,brow=6,lift=4),F(200,100,0,0,w=50,s=4,brow=5,lift=4),
    F(700,1400,85,85,x=-3,w=55,s=8,brow=4,lift=4)]),
  ('pleading','부탁','🥺',LOVE,'초롱초롱한 눈으로 간절히 바라봐요',None,[
    F(500,1200,y=-4,w=26,s=-4,eyes=BIG,brow=8,lift=7),F(300,500,y=-5,w=22,s=-6,o=4,eyes=BIG,brow=9,lift=8,shake=1),
    F(160,80,0,0,y=-4,w=26,s=-4,brow=8,lift=7),F(500,1300,x=-4,y=-4,w=26,s=-2,eyes=BIG,brow=8,lift=7,fx=SPARKLE)]),
  # ----- 놀람·관심 -----
  ('surprised','놀람','!',WONDER,'눈썹이 번쩍, 작은 입이 벌어져요',None,[
    F(120,700,y=-3,w=22,s=0,o=30,lift=10,fx=EXCLAIM),F(150,120,25,25,w=25,s=0,o=18,lift=9),
    F(120,1000,w=24,s=0,o=28,lift=10,fx=EXCLAIM),F(650,800,80,80,w=38,s=3,o=4,lift=6)]),
  ('curious','호기심','?',WONDER,'두리번거리며 궁금해해요',4,[
    F(450,1100,x=-12,s=4,w=40,lift=6,brow=3),F(450,900,x=12,y=-5,s=6,w=40,lift=7,brow=3,fx=QUESTION),
    F(100,40,0,0,s=4,w=40,lift=6),F(200,1000,y=-7,w=25,s=0,o=16,lift=8,fx=QUESTION),F(600,1300,s=10,lift=5)]),
  ('awe','경탄','🤩',WONDER,'반짝이는 눈으로 입을 벌리고 감탄해요',None,[
    F(800,1400,y=-6,w=30,s=2,o=20,lift=11,fx=SPARKLE),F(600,1200,y=-7,w=32,s=4,o=24,eyes=STAR,lift=10,fx=SPARKLE),
    F(200,100,0,0,y=-6,w=30,s=2,o=20,lift=10),F(700,1500,x=-6,y=-8,w=28,s=2,o=22,lift=11,fx=SPARKLE)]),
  ('eager','기대','✨',WONDER,'통통 튀며 두근두근 기다려요',None,[
    F(200,300,y=-4,w=60,s=20,o=6,eyes=BIG,lift=7),F(200,300,y=2,w=60,s=20,o=6,eyes=BIG,lift=7),
    F(200,300,y=-4,w=62,s=22,o=8,eyes=BIG,lift=7,fx=SPARKLE),F(200,300,y=2,w=62,s=22,o=8,eyes=BIG,lift=7),
    F(150,80,0,0,w=60,s=20,lift=7),F(400,900,x=6,y=-3,w=60,s=22,eyes=BIG,lift=8,fx=SPARKLE)]),
  ('idea','아이디어','💡',WONDER,'위를 보다가 전구가 반짝, 신이 나요',None,[
    F(300,500,x=4,y=-6,w=40,s=4,lift=7,fx=BULB),F(200,700,y=-4,w=70,s=20,o=10,lift=8,eyes=BIG,fx=BULB),
    F(300,900,w=85,s=24,o=16,eyes=STAR,lift=7,fx=BULB|SPARKLE,color=YELLOW)]),
  ('realization','깨달음','❗',WONDER,'멈칫, 번뜩! 하고 알아차려요',None,[
    F(600,1000,70,70,x=8,y=-6,w=40,s=0,lift=4),F(120,600,w=24,s=0,o=20,lift=11,fx=EXCLAIM),
    F(300,1200,w=75,s=22,o=10,lift=9,fx=EXCLAIM|SPARKLE),F(500,800,w=70,s=20,lift=6)]),
  ('shocked','충격','😱',WONDER,'눈이 점처럼 작아지고 입이 떡 벌어져요',None,[
    F(100,900,w=40,s=0,o=30,eyes=DOT,lift=12,shake=3),F(200,400,y=2,w=44,s=-4,o=28,eyes=DOT,lift=12,shake=1),
    F(100,80,0,0,w=40,s=0,o=24,lift=12),F(150,1000,w=40,s=0,o=30,eyes=DOT,lift=12,shake=2,fx=EXCLAIM),
    F(600,700,90,90,w=40,s=-4,o=10,lift=9)]),
  ('confused','혼란','❓',WONDER,'짝짝이 눈과 삐뚤어진 입, 물음표',None,[
    F(500,1000,100,55,x=-6,y=-4,w=40,s=0,brow=4,lift=6,tilt=6,fx=QUESTION),
    F(500,900,55,100,x=6,y=-4,w=40,s=0,brow=4,lift=6,tilt=-6,fx=QUESTION),
    F(140,80,0,0,w=40,s=0,brow=4,lift=6),F(400,1200,90,70,w=38,s=-3,brow=5,lift=7,tilt=4,fx=QUESTION)]),
  # ----- 생각·대화 -----
  ('determined','결의','💪',MIND,'눈에 힘을 주고 입을 꾹, 이제 해볼게요',None,[
    F(400,900,60,60,w=50,s=6,lift=5,brow=-5),F(200,250,60,60,y=4,w=50,s=6,lift=5,brow=-5),
    F(200,250,60,60,y=-1,w=52,s=8,lift=5,brow=-5),F(400,1200,55,55,w=55,s=10,lift=6,brow=-6,fx=SPARKLE)]),
  ('serious','진지함','😐',MIND,'일자 입에 눈썹을 살짝 모으고 차분하게',None,[
    F(600,2000,85,85,w=50,s=0,lift=4,brow=-1),F(120,80,0,0,w=50,s=0,lift=4,brow=-1),
    F(500,1800,85,85,x=-4,w=50,s=-1,lift=4,brow=-2),F(500,1500,85,85,w=48,s=0,lift=5,brow=-1)]),
  ('thinking','생각 중','…',MIND,'위쪽을 바라보며 골똘히 생각해요',None,[
    F(700,2100,80,55,x=9,y=-9,w=40,s=0,lift=6,brow=2,tilt=4),F(140,80,0,0,x=9,y=-9,w=40,s=0,lift=6),
    F(550,1700,70,90,x=-8,y=-7,w=35,s=-3,lift=6,brow=2,tilt=-4),F(650,1100,90,90,w=45,s=5,lift=5)]),
  ('skeptical','의심','¿',MIND,'눈을 좁히고 입꼬리를 비틀어요',None,[
    F(400,1400,25,100,x=10,w=55,s=0,brow=-3,lift=4,tilt=5),F(550,900,25,100,x=-7,w=55,s=-3,brow=-3,lift=4,tilt=6),
    F(130,70,0,0,w=55,s=0,lift=4),F(400,1600,100,30,x=-10,w=50,s=0,brow=-3,lift=4,tilt=-5)]),
  ('focused','집중','🎯',MIND,'눈을 가늘게 뜨고 한곳을 응시해요',None,[
    F(600,3000,55,55,w=30,s=0,brow=-2,lift=2),F(400,1500,55,55,x=3,w=28,s=-2,brow=-3,lift=2),
    F(120,60,0,0,w=30,s=0,brow=-2,lift=2),F(500,2500,60,60,x=-2,w=30,s=0,brow=-2,lift=2)]),
  ('listening','듣는 중','👂',MIND,'고개를 끄덕이며 귀 기울여요',None,[
    F(500,700,y=-2,w=45,s=10,lift=5),F(350,200,y=6,w=45,s=10,lift=5),F(350,700,y=-2,w=45,s=12,lift=5),
    F(350,200,y=6,w=45,s=12,lift=5),F(130,70,0,0,w=45,s=10,lift=5),F(600,1200,x=6,w=48,s=12,lift=6)]),
  ('talking','말하는 중','💬',MIND,'입을 오물오물 움직이며 말해요',None,[
    F(100,60,w=45,s=10,o=18,lift=5),F(90,50,w=42,s=8,o=6,lift=5),F(110,70,w=48,s=10,o=22,lift=6),
    F(90,40,w=40,s=8,o=4,lift=5),F(100,60,w=46,s=12,o=14,lift=5),F(120,200,w=44,s=10,o=0,lift=5),
    F(100,60,x=4,w=46,s=10,o=20,lift=6),F(90,50,x=4,w=42,s=8,o=8,lift=5),F(100,40,0,0,x=4,w=44,s=10,o=2,lift=5),
    F(110,300,x=2,w=45,s=12,o=12,lift=5)]),
  ('processing','처리 중','⟳',MIND,'눈동자를 빙글 돌리며 계산해요',None,[
    F(250,150,70,70,x=10,y=-6,w=30,s=0,color=BLUE),F(250,150,70,70,x=0,y=-9,w=30,s=0,color=BLUE),
    F(250,150,70,70,x=-10,y=-6,w=30,s=0,color=BLUE),F(250,150,70,70,x=-10,y=4,w=30,s=0,color=BLUE),
    F(250,150,70,70,x=0,y=7,w=30,s=0,color=BLUE),F(250,150,70,70,x=10,y=4,w=30,s=0,color=BLUE),
    F(120,60,0,0,w=30,s=0,color=BLUE),F(400,1000,w=50,s=12,lift=5,fx=SPARKLE)]),
  # ----- 평온·휴식 -----
  ('calm','차분함','◡',REST,'느긋한 눈 깜빡임과 시선',1,[
    F(400,800,s=0),F(400,800,x=-10,s=0),F(100,40,0,0,s=0),F(180,1200,s=0,eyes=CALM),F(400,800,x=10,s=3)]),
  ('sleepy','졸림','☾',REST,'스르르 감기는 눈과 하품',3,[
    F(1000,1400,40,40,s=0,brow=3,lift=3),F(1400,1600,0,0,w=30,s=0,fx=ZZZ),
    F(1200,1200,20,20,w=35,s=0,o=24,fx=ZZZ),F(700,1000,50,50,s=0,brow=3,lift=3)]),
  ('bored','심심함','−',REST,'반쯤 뜬 눈으로 느리게 둘러봐요',None,[
    F(1200,2200,30,30,x=-12,w=65,s=-3,lift=2),F(1600,2400,30,30,x=12,w=65,s=-3,lift=2,tilt=3),
    F(650,450,0,0,w=65,s=-3,lift=2),F(1100,2000,35,35,w=65,s=0,lift=2)]),
  ('relieved','안도','😮‍💨',REST,'"휴~" 숨을 내쉬고 편안해져요',None,[
    F(600,600,90,90,w=50,s=0,brow=5,lift=5),F(800,900,y=4,w=30,s=0,o=14,eyes=CALM,brow=4,lift=4),
    F(700,1400,y=2,w=60,s=16,eyes=CALM,brow=2,lift=4),F(600,1200,85,85,w=62,s=16)]),
  ('goodnight','잘 자','🌙',REST,'눈을 감고 살짝 웃으며 잘 자요 인사',None,[
    F(700,1500,40,40,w=55,s=14),F(600,2500,w=55,s=16,eyes=CALM,fx=ZZZ),
    F(500,2500,y=2,w=52,s=14,eyes=CALM,fx=ZZZ|BLUSH)]),
  ('sleeping','잠','💤',REST,'눈을 감고 새근새근 잠들어요',SLEEPING_SLOT,[
    F(1500,1000,0,0,y=4,w=24,s=0,o=4,fx=ZZZ),F(1500,1000,0,0,y=6,w=26,s=0,o=10,fx=ZZZ),
    F(1500,1200,0,0,y=4,w=24,s=2,o=2,fx=ZZZ)]),
  ('waking','기상','🌅',REST,'부스스 눈을 뜨고 하품 후 활짝',None,[
    F(1200,800,0,0,y=5,w=30,s=0,fx=ZZZ),F(1000,500,30,30,y=4,w=30,s=0),F(800,1000,20,20,y=2,w=34,s=0,o=26),
    F(500,300,50,50,w=40,s=0),F(120,80,0,0,w=40,s=0),F(300,1400,w=60,s=16,lift=7)]),
  ('dazed','멍함','😶',REST,'작은 눈으로 허공을 멍하니 봐요',None,[
    F(1500,2500,x=-4,y=3,w=24,s=0,o=6,eyes=DOT),F(1800,2500,x=4,y=4,w=22,s=0,o=8,eyes=DOT),
    F(400,200,0,0,w=24,s=0),F(1500,2000,y=2,w=26,s=0,o=4,eyes=DOT)]),
  # ----- 슬픔 -----
  ('sad','슬픔','☹',SAD,'처진 눈썹과 느린 움직임',2,[
    F(400,800,60,60,y=5,s=-20,brow=7,lift=4),F(150,100,0,0,y=5,s=-20,brow=7,lift=4),
    F(300,1800,60,60,x=-6,y=7,s=-24,brow=8,lift=4)]),
  ('crying','울음','😭',SAD,'눈물을 뚝뚝 흘리며 엉엉 울어요',None,[
    F(400,800,40,40,y=4,w=50,s=-20,o=12,brow=9,lift=6,fx=TEAR),
    F(250,400,y=5,w=56,s=-24,o=20,eyes=SQUEEZE,brow=10,lift=6,fx=TEAR,shake=2),
    F(300,600,30,30,y=4,w=48,s=-18,o=8,brow=9,lift=6,fx=TEAR,shake=1),
    F(250,400,y=5,w=58,s=-26,o=24,eyes=SQUEEZE,brow=10,lift=6,fx=TEAR,shake=2),
    F(500,900,45,45,y=4,w=46,s=-18,o=4,brow=8,lift=5,fx=TEAR,color=BLUE)]),
  ('disappointed','실망','😞',SAD,'웃다가 입꼬리가 서서히 내려가요',None,[
    F(400,600,w=60,s=14,lift=6),F(900,500,70,70,y=6,w=55,s=-6,brow=5,lift=4),
    F(800,1800,55,55,x=-4,y=8,w=55,s=-14,brow=6,lift=3),F(150,100,0,0,y=8,w=55,s=-14,brow=6,lift=3),
    F(900,1600,55,55,x=4,y=8,w=52,s=-16,brow=6,lift=3,color=BLUE)]),
  ('lonely','외로움','🌧',SAD,'푸른빛으로 먼 곳을 바라봐요',None,[
    F(1500,2200,70,70,x=-12,y=3,w=30,s=-6,brow=5,lift=4,color=BLUE),
    F(1800,2400,70,70,x=12,y=4,w=30,s=-6,brow=5,lift=4,color=BLUE),
    F(500,300,0,0,y=6,w=30,s=-6,brow=5,lift=4,color=BLUE),F(1500,2000,60,60,y=7,w=28,s=-8,brow=6,lift=4,color=PURPLE)]),
  ('rueful','아쉬움','🥲',SAD,'웃는데 갸웃, 땀 한 방울로 아쉬워해요',None,[
    F(500,1200,80,80,w=60,s=10,tilt=4,lift=5,brow=4),F(400,1200,x=4,w=58,s=8,tilt=5,eyes=ARC,lift=5,brow=5,fx=SWEAT),
    F(120,80,0,0,x=4,w=58,s=8,tilt=5,lift=5,brow=5),F(500,1400,75,75,w=60,s=10,tilt=3,lift=5,brow=4)]),
  ('apologetic','미안함','🙇',SAD,'고개를 숙이고 진땀을 흘려요',None,[
    F(600,800,80,80,y=3,w=40,s=-6,brow=8,lift=5),F(700,1000,y=9,w=36,s=-8,eyes=CALM,brow=8,lift=5,fx=SWEAT),
    F(500,800,75,75,x=-5,y=5,w=38,s=-4,o=4,brow=8,lift=5,fx=SWEAT),F(150,80,0,0,y=4,w=38,s=-6,brow=7,lift=5)]),
  ('sulky','서운함','😤',SAD,'고개를 홱 돌리고 입을 삐죽여요',None,[
    F(500,1400,60,60,x=-12,w=18,s=-8,brow=-3,lift=3),F(300,600,60,60,x=-12,y=2,w=16,s=-10,o=4,brow=-4,lift=3),
    F(400,800,70,70,x=6,w=20,s=-6,brow=-2,lift=3),F(300,1400,55,55,x=-13,w=18,s=-10,brow=-4,lift=3,fx=BLUSH)]),
  ('exhausted','지침','😩',SAD,'축 처진 눈에 땀, 기운이 없어요',None,[
    F(1000,1500,30,30,y=6,w=40,s=-6,o=8,brow=4,lift=3,fx=SWEAT),F(1200,600,10,10,y=8,w=44,s=-8,o=14,brow=4,lift=3,fx=SWEAT),
    F(900,1500,35,35,y=6,w=40,s=-6,o=6,brow=4,lift=3),F(600,400,0,0,y=8,w=40,s=-6,o=4)]),
  # ----- 불안·긴장 -----
  ('afraid','두려움','◉',TENSE,'좌우를 급히 살피며 움츠러들어요',None,[
    F(140,280,x=-12,y=5,w=38,s=-8,o=12,brow=8,lift=7,shake=1),F(150,240,x=12,y=5,w=38,s=-8,o=12,brow=8,lift=7,shake=1),
    F(100,100,0,0,y=6,w=32,s=-15,brow=8,lift=7),F(180,650,x=-5,y=5,w=35,s=-10,o=15,brow=9,lift=8,shake=2),
    F(140,350,x=7,y=5,w=35,s=-10,o=10,brow=8,lift=7,shake=1),F(500,800,75,75,y=6,w=40,s=-12,brow=7,lift=6)]),
  ('worried','걱정','😟',TENSE,'눈썹을 모으고 아래를 서성여요',None,[
    F(800,1200,85,85,x=-6,y=4,w=36,s=-8,brow=8,lift=5),F(800,1200,85,85,x=6,y=4,w=36,s=-8,brow=8,lift=5,tilt=3),
    F(200,120,0,0,y=4,w=36,s=-8,brow=8,lift=5),F(700,1400,80,80,y=6,w=32,s=-10,brow=9,lift=6,fx=SWEAT)]),
  ('nervous','긴장','😬',TENSE,'식은땀과 함께 덜덜, 어색한 미소',None,[
    F(150,300,x=-6,w=44,s=-4,brow=6,lift=6,fx=SWEAT,shake=1),F(150,300,x=6,w=44,s=-4,brow=6,lift=6,fx=SWEAT,shake=1),
    F(100,60,0,0,w=44,s=-4,brow=6,lift=6,shake=1),F(150,400,y=2,w=46,s=4,brow=6,lift=6,tilt=-4,fx=SWEAT,shake=1),
    F(150,300,x=-8,w=44,s=-4,brow=6,lift=6,fx=SWEAT,shake=1),F(500,700,90,90,w=44,s=2,brow=5,lift=6,tilt=3,fx=SWEAT)]),
  ('flustered','당황','😳',TENSE,'얼굴이 달아오르고 눈이 휘둥그레',None,[
    F(120,400,x=-10,w=40,s=-4,o=10,eyes=DOT,lift=9,fx=SWEAT|BLUSH),F(120,400,x=10,w=40,s=-4,o=10,eyes=DOT,lift=9,fx=SWEAT|BLUSH),
    F(100,60,0,0,w=40,s=-4,o=10,lift=9,fx=BLUSH),F(150,500,w=44,s=6,o=6,eyes=SQUEEZE,lift=8,fx=SWEAT|BLUSH,shake=1),
    F(400,900,90,90,x=-6,y=4,w=40,s=4,lift=7,fx=BLUSH)]),
  ('hopeful','조마조마','🤞',TENSE,'두 손을 모으고 눈을 질끈, 잘 되길 빌어요',None,[
    F(300,900,w=30,s=2,eyes=SQUEEZE,lift=5,brow=5,fx=PRAY,shake=1),F(250,600,70,70,x=-3,w=32,s=0,lift=6,brow=6,fx=PRAY),
    F(300,1000,w=30,s=2,eyes=SQUEEZE,lift=5,brow=5,fx=PRAY|SWEAT,shake=1)]),
  ('awkward','민망함','😅',TENSE,'땀 한 방울과 함께 멋쩍게 웃어요',None,[
    F(400,1400,w=70,s=14,eyes=ARC,tilt=4,fx=SWEAT),F(500,900,80,80,x=10,w=60,s=8,brow=4,lift=5,tilt=5,fx=SWEAT),
    F(150,60,0,0,w=60,s=8,tilt=5),F(400,1200,w=72,s=16,eyes=ARC,tilt=3,fx=SWEAT|BLUSH)]),
  ('terrified','공포','😨',TENSE,'보랏빛으로 질려 와들와들 떨어요',None,[
    F(100,700,y=3,w=50,s=-14,o=26,eyes=DOT,brow=9,lift=11,shake=4,color=PURPLE),
    F(150,500,x=-10,y=5,w=46,s=-12,o=22,eyes=DOT,brow=9,lift=11,shake=3,color=PURPLE),
    F(150,500,x=10,y=5,w=46,s=-12,o=22,eyes=DOT,brow=9,lift=11,shake=3,color=PURPLE),
    F(100,60,0,0,y=4,w=46,s=-12,o=20,brow=9,lift=11,shake=3,color=PURPLE),
    F(300,700,y=4,w=50,s=-16,o=28,brow=10,lift=12,shake=4,fx=SWEAT,color=PURPLE)]),
  ('cringe','오글거림','><',TENSE,'> < 눈을 질끈 감고 몸서리쳐요',None,[
    F(200,900,w=60,s=-6,eyes=SQUEEZE,tilt=-5,shake=1,fx=SWEAT),F(400,700,40,40,x=-12,w=55,s=-4,brow=5,lift=4,tilt=5),
    F(200,800,y=3,w=64,s=-8,eyes=SQUEEZE,tilt=4,shake=2,fx=SWEAT),F(500,900,60,60,x=10,w=55,s=-2,brow=5,lift=4)]),
  # ----- 분노·불쾌 -----
  ('angry','화남','💢',ANGRY,'눈썹을 찌푸리고 입을 꾹 다물어요',None,[
    F(250,1100,25,25,w=80,s=-20,brow=-8,lift=2),F(180,450,20,20,x=-6,w=90,s=-24,brow=-9,lift=2,fx=ANGER),
    F(180,450,20,20,x=6,w=90,s=-24,brow=-9,lift=2,fx=ANGER,color=RED),F(120,100,0,0,w=85,s=-20,brow=-8,lift=2),
    F(180,1300,30,30,w=80,s=-22,brow=-8,lift=2,fx=ANGER)]),
  ('furious','격노','🔥',ANGRY,'새빨개져서 부들부들 떨어요',None,[
    F(200,600,30,30,w=80,s=-22,o=10,brow=-10,lift=1,fx=ANGER,color=RED,shake=2),
    F(150,400,25,25,y=-2,w=90,s=-26,o=20,brow=-10,lift=1,fx=ANGER,color=RED,shake=4),
    F(200,500,30,30,w=85,s=-24,o=12,brow=-9,lift=1,fx=ANGER,color=RED,shake=3),
    F(100,60,0,0,w=85,s=-24,o=8,brow=-10,lift=1,color=RED,shake=2),
    F(300,700,30,30,w=80,s=-22,o=6,brow=-10,lift=1,fx=ANGER,color=ORANGE,shake=2)]),
  ('annoyed','짜증','🙄',ANGRY,'눈을 위로 굴리며 한숨 쉬어요',None,[
    F(500,800,55,55,w=55,s=-6,brow=-3,lift=3),F(400,200,70,70,x=-10,y=-9,w=55,s=-6,brow=-1,lift=5),
    F(300,200,70,70,y=-10,w=55,s=-6,brow=-1,lift=5),F(300,500,70,70,x=10,y=-9,w=55,s=-6,brow=-1,lift=5),
    F(500,1200,45,45,w=55,s=-8,brow=-4,lift=2,tilt=-4,fx=ANGER),F(120,60,0,0,w=55,s=-8,brow=-4,lift=2)]),
  ('disgusted','싫음','×',ANGRY,'눈을 찡그리고 고개를 돌려요',None,[
    F(350,1000,18,45,x=-12,w=48,s=-24,brow=-4,lift=3,tilt=-4),F(250,550,10,30,x=-15,y=-3,w=38,s=-26,brow=-5,lift=3,tilt=-6),
    F(150,140,0,0,x=-12,w=40,s=-22,brow=-4,lift=3),F(600,1100,35,55,x=-8,w=48,s=-18,brow=-3,lift=3,tilt=-3,color=GREEN)]),
  ('contempt','경멸','😒',ANGRY,'한쪽 입꼬리만 올리고 내려다봐요',None,[
    F(600,1600,45,45,x=8,y=3,w=55,s=0,brow=-2,lift=4,tilt=9),F(500,1200,40,40,x=12,y=4,w=50,s=-2,brow=-3,lift=4,tilt=10),
    F(150,80,0,0,w=55,s=0,lift=4,tilt=9),F(600,1400,50,50,x=-6,y=2,w=55,s=0,brow=-2,lift=4,tilt=8)]),
  ('jealous','질투','😾',ANGRY,'곁눈질하며 입을 삐죽, 부글부글',None,[
    F(600,1500,50,50,x=-13,w=30,s=-10,brow=-4,lift=3),F(400,700,45,45,x=-14,y=2,w=26,s=-12,brow=-5,lift=2,tilt=-4),
    F(150,80,0,0,w=30,s=-10,brow=-4,lift=3),F(500,1300,55,55,x=12,w=32,s=-8,brow=-3,lift=3,fx=ANGER)]),
  # ----- 몸 상태 -----
  ('sick','아픔','🤢',BODY,'초록빛 얼굴로 울렁거려요',None,[
    F(800,1200,50,50,y=3,w=50,s=-8,brow=6,lift=4,tilt=5,fx=SWEAT,color=GREEN),
    F(800,1200,45,45,y=4,w=50,s=-8,brow=6,lift=4,tilt=-5,fx=SWEAT,color=GREEN,shake=1),
    F(300,200,0,0,y=4,w=50,s=-8,brow=6,lift=4,color=GREEN),F(600,900,40,40,y=5,w=36,s=-4,o=12,brow=7,lift=4,color=GREEN)]),
  ('dizzy','어지러움','💫',BODY,'빙글빙글 소용돌이 눈',None,[
    F(500,600,x=-6,y=-3,w=50,s=0,o=6,eyes=SPIRAL,tilt=5),F(500,600,x=6,y=-3,w=50,s=0,o=6,eyes=SPIRAL,tilt=-5),
    F(500,600,x=6,y=4,w=50,s=0,o=10,eyes=SPIRAL,tilt=5),F(500,600,x=-6,y=4,w=50,s=0,o=8,eyes=SPIRAL,tilt=-5)]),
  ('cold','추움','🥶',BODY,'파랗게 질려 이를 딱딱 떨어요',None,[
    F(300,800,70,70,w=50,s=-6,o=6,brow=6,lift=5,shake=3,color=BLUE),F(300,800,60,60,y=2,w=46,s=-8,o=4,brow=7,lift=5,shake=4,color=BLUE),
    F(150,80,0,0,w=48,s=-6,brow=6,lift=5,shake=3,color=BLUE),F(400,900,w=52,s=-6,o=8,eyes=SQUEEZE,brow=7,lift=5,shake=4,color=BLUE)]),
  ('hot','더움','🥵',BODY,'주황빛 얼굴로 헥헥, 땀이 송골송골',None,[
    F(400,400,50,50,y=3,w=40,s=-2,o=18,brow=4,lift=4,fx=SWEAT,color=ORANGE),F(300,300,45,45,y=4,w=40,s=-2,o=8,brow=4,lift=4,fx=SWEAT,color=ORANGE),
    F(400,400,50,50,y=3,w=42,s=0,o=20,brow=4,lift=4,fx=SWEAT,color=RED),F(300,300,40,40,y=4,w=40,s=-2,o=6,brow=4,lift=4,fx=SWEAT,color=ORANGE),
    F(200,100,0,0,y=4,w=40,s=-2,o=10,brow=4,lift=4,fx=SWEAT,color=ORANGE)]),
  ('hungry','배고픔','🍙',BODY,'큰 눈으로 먹을 것을 찾아 두리번',None,[
    F(600,1200,x=-8,y=6,w=30,s=0,o=14,eyes=BIG,brow=5,lift=5),F(600,1000,x=8,y=6,w=32,s=2,o=10,eyes=BIG,brow=5,lift=5),
    F(400,800,60,60,y=4,w=40,s=-6,brow=6,lift=4,tilt=4),F(150,80,0,0,y=4,w=40,s=-6,brow=6,lift=4)]),
  ('knocked_out','기절','😵',BODY,'X 눈에 별이 빙빙 돌아요',None,[
    F(300,2000,w=40,s=-4,o=14,eyes=CROSS,tilt=6,fx=SPARKLE),F(800,2000,y=3,w=42,s=-6,o=10,eyes=CROSS,tilt=-6,fx=SPARKLE),
    F(800,1600,x=-3,y=2,w=40,s=-4,o=16,eyes=CROSS,tilt=4)]),
]


def _catalog():
    moods=[dict(id=k,name=n,icon=i,group=g,description=d,slot=7 if s is None else s,frames=f)
           for k,n,i,g,d,s,f in CATALOG]
    by={m['id']:m['frames'] for m in moods}
    mix=by['calm'][:4]+by['curious'][:4]+by['happy'][:5]+by['playful'][:3]+by['love'][:2]+by['sleepy'][:4]
    moods.append(dict(id='auto',name='자동',icon='↻',group='자동',
                      description='차분함·호기심·행복·장난·사랑·졸림을 차례로',slot=7,frames=mix))
    return moods


def defaults():
    """Starter modes for the editor: the four moods with dedicated slots 1-4."""
    by={m['id']:m for m in _catalog()}
    return [dict(slot=i,name=name,frames=by[key]['frames'])
            for i,(key,name) in enumerate([('happy','Happy'),('calm','Neutral'),('sad','Sad'),('sleepy','Sleepy')])]


def load():
    if not PATH.exists(): return defaults()
    data=json.loads(PATH.read_text())
    if not isinstance(data,list) or len(data)>SLOTS: raise ValueError(T('저장된 모드 파일 형식이 올바르지 않습니다.','The saved modes file is invalid.'))
    modes=[validate(m) for m in data]
    if len({m['slot'] for m in modes})!=len(modes): raise ValueError(T('중복된 저장 위치가 있습니다.','Two modes use the same slot.'))
    return modes


def save(mode):
    mode=validate(mode)
    modes=[m for m in load() if m['slot']!=mode['slot']]+[mode]
    modes.sort(key=lambda m:m['slot'])
    temp=PATH.with_suffix('.tmp')
    temp.write_text(json.dumps(modes,ensure_ascii=False,indent=2))
    temp.replace(PATH)
    return mode


def commands(mode, play=True):
    m=validate(mode)
    yield f"BEGIN:{m['slot']}:{len(m['frames'])}",'OK BEGIN'
    for f in m['frames']:
        yield 'FRAME:'+','.join(str(f[k]) for k in FIELDS),'OK FRAME'
    yield 'COMMIT','OK COMMIT'
    if play:
        yield f"PLAY:{m['slot']}",'OK PLAY'


def checksum(mode):
    """Same value as modeSum() in the firmware (reply to SUM:<slot>)."""
    m=validate(mode)
    s=len(m['frames'])
    for f in m['frames']:
        for k in FIELDS:
            s=(s*31+f[k]+20000)&0xFFFFFFFF
    return s


def idle_moods():
    """The faces the board switches to by itself when idle (sleepy, sleeping)."""
    by={m['id']:m for m in emotions()}
    return [by['sleepy'],by['sleeping']]


def duration_text(seconds):
    h,rest=divmod(seconds,3600);m,sec=divmod(rest,60)
    if lang()=='ko':
        parts=[f'{h}시간' if h else '',f'{m}분' if m else '',f'{sec}초' if sec else '']
        return ' '.join(x for x in parts if x) or '0초'
    parts=[f'{h} h' if h else '',f'{m} min' if m else '',f'{sec} s' if sec else '']
    return ' '.join(x for x in parts if x) or '0 s'


def timer_command(left, total, color='blue'):
    """left/total in seconds; left=0 cancels the timer."""
    for v in (left,total):
        if type(v) is not int or not 0<=v<=MAX_SECONDS: raise ValueError(T('타이머는 24시간 이하로 설정해 주세요.','Timers can be up to 24 hours.'))
    if left>total: raise ValueError(T('남은 시간이 전체 시간보다 깁니다.','Time left is longer than the total.'))
    if color not in TIMER_COLORS: raise ValueError(T('타이머 색: ','Timer colors: ')+', '.join(TIMER_COLORS))
    return f'TIMER:{left}:{total}:{TIMER_COLORS.index(color)}','OK TIMER'


def validate_saver(saver):
    if not isinstance(saver,dict): raise ValueError(T('대기 화면 설정 형식이 올바르지 않습니다.','Invalid screen saver settings.'))
    v=dict(SAVER_DEFAULT,**{k:saver[k] for k in SAVER_DEFAULT if k in saver})
    if type(v['after']) is not int or not 1<=v['after']<=1440: raise ValueError(T('대기 시간은 1~1440분 정수로 입력해 주세요.','The wait must be 1-1440 whole minutes.'))
    if v['type'] not in SAVER_TYPES: raise ValueError(T('대기 화면 종류: ','Screen saver types: ')+', '.join(SAVER_TYPES))
    if type(v['clock']) is not bool: raise ValueError(T('시계 겹치기 값이 올바르지 않습니다.','Invalid clock overlay value.'))
    if type(v['slide']) is not int or not 5<=v['slide']<=3600: raise ValueError(T('슬라이드 간격은 5~3600초로 입력해 주세요.','Slides change every 5-3600 seconds.'))
    return v


def saver_command(saver):
    v=validate_saver(saver)
    return f"SAVER:{v['after']*60}:{SAVER_TYPES.index(v['type'])}:{int(v['clock'])}:{v['slide']}",'OK SAVER'


def load_settings():
    """{'saver': {...}, 'timer': {'end': epoch, 'total': s, 'color': name} or None}"""
    try:
        data=json.loads(SETTINGS.read_text())
        if not isinstance(data,dict): raise ValueError
    except (OSError,ValueError):
        data={}
    old=data.get('idle')   # FACE5/6 idle stages: keep the first delay
    if 'saver' not in data and isinstance(old,dict) and type(old.get('sleepy')) is int and old['sleepy']>0:
        data['saver']=dict(SAVER_DEFAULT,after=old['sleepy'])
    try:
        saver=validate_saver(data.get('saver',{}))
    except ValueError:
        saver=dict(SAVER_DEFAULT)
    timer=data.get('timer')
    if not (isinstance(timer,dict) and isinstance(timer.get('end'),(int,float)) and type(timer.get('total')) is int
            and timer.get('color') in TIMER_COLORS):
        timer=None
    mono=data.get('mono') is True   # monochrome style: gray face, owner shown by ring pattern
    out=dict(saver=saver,timer=timer,mono=mono)
    if isinstance(data.get('language'),str):
        out['language']=data['language']   # written by the app's server for the MCP server
    return out


def save_settings(**changes):
    data=load_settings(); data.update(changes)
    SETTINGS.parent.mkdir(parents=True,exist_ok=True)
    temp=SETTINGS.with_name(SETTINGS.name+f'.{os.getpid()}.tmp')
    temp.write_text(json.dumps(data,ensure_ascii=False,indent=2))
    temp.replace(SETTINGS)
    return data


def style_command(mono):
    if type(mono) is not bool: raise ValueError(T('흑백 모드 값이 올바르지 않습니다.','Invalid monochrome value.'))
    return f'STYLE:{int(mono)}','OK STYLE'


def owner_command(owner):
    if owner not in OWNERS: raise ValueError(T('표정을 바꾼 주체는 user, claude, gpt 중 하나여야 합니다.','Who chose the face must be user, claude or gpt.'))
    return f'OWNER:{OWNERS.index(owner)}','OK OWNER'


def emotions():
    """Ready-to-play moods (71 + auto); every mood is its own animation loop.
    Stylized character states, not diagnostic human facial expressions."""
    ko=lang()=='ko'
    out=[]
    for m in _catalog():
        name_en,desc_en=EN[m['id']]
        gid=GROUP_IDS[m['group']]
        mood=validate(dict(slot=m['slot'],name=m['name'] if ko else name_en,frames=m['frames']))
        out.append(dict(id=m['id'],icon=m['icon'],group_id=gid,group=m['group'] if ko else GROUP_EN[gid],
                        description=m['description'] if ko else desc_en,
                        name_ko=m['name'],name_en=name_en,**mood))
    return out


def photo_checksum(data):
    """Same value the firmware computes while receiving (PHOTO:END:<sum>)."""
    s=0
    for b in data:
        s=(s*31+b)&0xFFFFFFFF
    return s


def check_photo(data):
    if not isinstance(data,(bytes,bytearray)) or len(data)!=PHOTO_BYTES:
        raise ValueError(T('사진 데이터 크기가 올바르지 않습니다. 앱에서 다시 올려 주세요.','The photo data has the wrong size. Add it again in the app.'))
    return bytes(data)


def photo_copy(pid):
    return PHOTO_DIR/f'{pid}.rgb565'


def local_photo(pid):
    """Mac copy of board photo <pid>, or None."""
    if type(pid) is not int or not 0<=pid<MAX_PHOTOS: return None
    try:
        if pid==0 and not photo_copy(0).exists() and LEGACY_PHOTO.exists():
            PHOTO_DIR.mkdir(parents=True,exist_ok=True); LEGACY_PHOTO.replace(photo_copy(0))
        data=photo_copy(pid).read_bytes()
        return data if len(data)==PHOTO_BYTES else None
    except OSError:
        return None


def parse_photo_list(reply):
    """'OK LIST:<mask>:<current>' -> ([ids], current id or -1)"""
    try:
        mask,current=reply.split(':')[1:3]; mask=int(mask); current=int(current)
    except (ValueError,IndexError):
        raise ValueError(T('보드의 사진 목록 응답이 올바르지 않습니다: ','Unexpected photo list from the board: ')+reply)
    return [i for i in range(MAX_PHOTOS) if mask>>i&1],current
