#include <Adafruit_GFX.h>
#include <Adafruit_GC9A01A.h>
#include <SPI.h>
#include <Preferences.h>
#include <math.h>
#include <LittleFS.h>

#define TFT_CS 2
#define TFT_RST 3
#define TFT_DC 4
#define TFT_SCK 7
#define TFT_MOSI 9
Adafruit_GC9A01A tft(TFT_CS, TFT_DC, TFT_RST);

// Face area: canvas 200x180 copied to screen (20,30). All drawing below
// uses screen coordinates; the S() helpers subtract the canvas offset.
const int OX=20, OY=30, CW=200, CH=180;
GFXcanvas16 canvas(CW, CH);
Preferences prefs;
const int CX=120, CY=120;
int clockHour=12, clockMinute=0, clockSecond=0;
uint32_t clockStartMillis=0, lastClockUpdate=0;
int oldHX=CX, oldHY=CY, oldMX=CX, oldMY=CY, oldSX=CX, oldSY=CY;

// ===== FACE8 = FACE3 frames + owner ring + countdown timer ring + photos + screen saver
// + monochrome style (FACE8) + wave / light bulb / praying hands effects (FACE8).
// Frame: 16 integers, data only (no executable code uploaded) =====
// 0 move ms, 1 hold ms, 2 left eye %, 3 right eye %, 4 gaze x, 5 gaze y,
// 6 mouth width, 7 smile, 8 mouth open, 9 brow tilt, 10 brow lift (0=hidden),
// 11 eye shape, 12 mouth tilt, 13 effect bits, 14 color index, 15 shake
enum { F_MOVE, F_HOLD, F_LEFT, F_RIGHT, F_X, F_Y, F_WIDTH, F_SMILE, F_OPEN,
       F_BROW, F_LIFT, F_EYES, F_TILT, F_FX, F_COLOR, F_SHAKE, F_COUNT };
const int32_t LO[F_COUNT]={80,0,0,0,-15,-10,10,-28,0,-10,0,0,-10,0,0,0};
const int32_t HI[F_COUNT]={5000,10000,100,100,15,10,100,28,30,10,12,9,10,8191,7,6};

// Eye shapes
enum { EYE_NORMAL, EYE_HAPPY, EYE_CALM, EYE_CROSS, EYE_HEART, EYE_SPIRAL,
       EYE_STAR, EYE_DOT, EYE_BIG, EYE_SQUEEZE };
// Effect bits
enum { FX_BLUSH=1, FX_TEAR=2, FX_SWEAT=4, FX_ZZZ=8, FX_HEARTS=16, FX_ANGER=32,
       FX_QUESTION=64, FX_EXCLAIM=128, FX_SPARKLE=256, FX_NOTE=512,
       FX_WAVE=1024, FX_BULB=2048, FX_PRAY=4096 };
// Face colors: white, pink, blue, yellow, red, green, purple, orange
const uint8_t PALETTE[8][3]={{255,255,255},{255,150,190},{120,180,255},{255,225,90},
                             {255,70,60},{130,220,110},{190,140,255},{255,160,60}};

struct Frame { int16_t v[F_COUNT]; };
struct Mode { uint32_t version, count; Frame frames[24]; };
const uint32_t MODE_VERSION=3;
// Slots 0-7 as before; slot 8 (FACE5) is reserved for the "sleeping" idle face.
const int SLOTS=9;
Mode modes[SLOTS], staging;
// active: face slot 0-8, CLOCK_SCREEN (-1) or PHOTO_SCREEN (-2).
const int CLOCK_SCREEN=-1, PHOTO_SCREEN=-2, FIRE_SCREEN=-3;
int active=CLOCK_SCREEN, savedActive=-99, uploadSlot=-1, received=0, target=0;

// Continuously interpolated values (frame index for each)
const int CONT[11]={F_LEFT,F_RIGHT,F_X,F_Y,F_WIDTH,F_SMILE,F_OPEN,F_BROW,F_LIFT,F_TILT,F_SHAKE};
enum { P_LEFT, P_RIGHT, P_X, P_Y, P_WIDTH, P_SMILE, P_OPEN, P_BROW, P_LIFT, P_TILT, P_SHAKE };
struct Pose { float v[11]; float rgb[3]; int eyes; int fx; };
Pose fromPose, pose;
uint32_t frameStart=0, lastDraw=0;

// ===== Owner ring: thin border showing who chose the face =====
// 0 = picked in the Mac app (white), 1 = Claude (Anthropic orange #D97757),
// 2 = GPT (ChatGPT green #10A37F). A new owner "pours" in clockwise from
// 12 o'clock with a soft blended edge instead of switching at once.
const uint8_t OWNER_RGB[3][3]={{255,255,255},{0xD9,0x77,0x57},{0x10,0xA3,0x7F}};
const int RING_IN=113, RING_OUT=119, RING_SEGS=180;   // 2-degree segments
const float RING_BAND=60.0f;                          // width of the blended edge (degrees)
const uint32_t RING_MS=1200;                          // sweep duration
// A clock hand drawn over a photo. Defined this early on purpose: the Arduino builder puts
// its generated function prototypes near the top (before the RingColorFn typedef below),
// so every type used in a function signature must be declared before that point.
struct Hand { float x0,y0,x1,y1,w; };
// Precomputed corner points of the 2-degree ring segments.
struct RingGeo { int16_t ix[RING_SEGS+1], iy[RING_SEGS+1], ox[RING_SEGS+1], oy[RING_SEGS+1]; };
RingGeo OWNER_RING;   // r 113-119: owner color (faces); the timer uses it on the clock screen
RingGeo TIMER_RING;   // r 104-110: countdown timer just inside the owner ring (faces)
typedef uint16_t (*RingColorFn)(float);
int owner=0, ringFrom=0;
// Monochrome style (STYLE:1): the face is drawn in grays and the owner ring shows who chose
// the face by its pattern instead of its color: app = solid, Claude = short dashes,
// GPT = six long arcs. Kept across restarts.
bool mono=false;
bool sweeping=false, ringDirty=true;
uint32_t sweepStart=0;
float ringHeadNow=360.0f+RING_BAND, headDrawn=0;
char lineBuffer[192]; int lineLength=0; bool overflow=false;
void drawClockFace();
void drawClock();

uint16_t rgb(int r,int g,int b) { return ((r&0xF8)<<8)|((g&0xFC)<<3)|(b>>3); }
const uint16_t C_BLACK=0;

// ===== Countdown timer (FACE5): TIMER:<seconds left>:<total seconds>:<color 0-7> =====
// The ring empties clockwise from 12 o'clock like a kitchen timer: the elapsed part is
// dimmed, the part still left stays bright. At zero the ring blinks for a few seconds.
enum { T_OFF, T_RUN, T_ALARM };
int cdState=T_OFF, cdColorIdx=2, cdSeg=-1;   // cdSeg = elapsed segments (0-180)
uint32_t cdEnd=0, cdTotal=1, alarmStart=0;
bool cdDirty=false, alarmOn=false;
const uint32_t ALARM_MS=8000, ALARM_BLINK=400;

// ===== Screen saver (FACE7): SAVER:<after s>:<type>:<clock on photos 0/1>:<slide s> =====
// Counted from the last PLAY (a face chosen by the app or an AI). When the face has not
// changed for <after> seconds the saver starts; the next PLAY or a timer alarm ends it.
//   0 sleep: sleepy face (slot 4), then asleep (slot 9) after twice the time
//   1 clock   2 photo (the current one)   3 slideshow (every photo in turn)   4 off
//   5 campfire (pixel-art fire, drawn live)
// Photo savers can draw clock hands on top of the picture.
enum { SV_SLEEP, SV_CLOCK, SV_PHOTO, SV_SLIDES, SV_OFF, SV_FIRE, SV_COUNT };
const int SLEEPY_SLOT=3, SLEEPING_SLOT=8;
int32_t saver[4]={600,SV_SLEEP,0,60};   // after s, type, clock overlay, slide s
int idleStage=0, chosenSlot=-1;
uint32_t idleStart=0, lastIdleCheck=0;
bool idleArmed=false, clockSynced=false;
// Saver notice: during the last 10 s before the saver starts, the inner ring (where the
// timer goes) fills up in soft purple so it is clear the face is about to change.
const int32_t NOTICE_MS=10000;
int noticeSeg=-1, noticeDrawn=-1;   // filled segments (0-180), -1 = not shown

// ===== Photos (FACE7): up to 10 pictures, each 240x240 RGB565 (little-endian, row by
// row) in LittleFS as /p<id>.raw. PHOTO:BEGIN:<id>:<bytes>, then PHOTO:DATA:<n> lines
// each followed by n raw bytes, then PHOTO:END:<checksum> stores and shows it.
// PHOTO:SHOW[:<id>], PHOTO:DEL:<id>, PHOTO:LIST -> OK LIST:<bit mask>:<current id>.
const int MAX_PHOTOS=10;
const uint32_t PHOTO_BYTES=240*240*2, PHOTO_CHUNK=4096;
const char *PHOTO_TMP="/photo.tmp";
bool fsReady=false;
File photoIn; uint32_t photoGot=0, photoSum=0; int photoInId=-1;
uint8_t photoBuf[PHOTO_CHUNK];
int currentPhoto=-1, shownPhoto=-1, lastPhotoMinute=-1;
bool photoOverlay=false, slideshow=false;
uint32_t lastSlide=0;

bool validFrame(const Frame &f) {
  for(int i=0;i<F_COUNT;i++) if(f.v[i]<LO[i] || f.v[i]>HI[i]) return false;
  return true;
}
bool validMode(const Mode &m) {
  if(m.version!=MODE_VERSION || m.count<1 || m.count>24) return false;
  for(uint32_t i=0;i<m.count;i++) if(!validFrame(m.frames[i])) return false;
  return true;
}
void initRing(RingGeo &r,int rIn,int rOut) {
  for(int i=0;i<=RING_SEGS;i++) {
    float a=i*2.0f*DEG_TO_RAD, s=sinf(a), c=cosf(a);
    r.ix[i]=CX+(int)roundf(rIn*s);  r.iy[i]=CY-(int)roundf(rIn*c);
    r.ox[i]=CX+(int)roundf(rOut*s); r.oy[i]=CY-(int)roundf(rOut*c);
  }
}
bool ringOn(int who,float a) {
  int i=(int)(a/2);
  if(who==1) return i%8<5;     // Claude: 22 short dashes
  if(who==2) return i%30<25;   // GPT: six long arcs
  return true;                 // app: solid
}
uint16_t ringColor(float a) {
  // u=1: new owner's color, u=0: previous color; smooth blend inside the band.
  float u=sweeping?constrain((ringHeadNow-a)/RING_BAND,0.0f,1.0f):1.0f;
  if(mono) return ringOn(u>=0.5f?owner:ringFrom,a)?0xFFFF:C_BLACK;
  u=u*u*(3-2*u);
  const uint8_t *n=OWNER_RGB[owner], *o=OWNER_RGB[ringFrom];
  return rgb((int)(o[0]+(n[0]-o[0])*u),(int)(o[1]+(n[1]-o[1])*u),(int)(o[2]+(n[2]-o[2])*u));
}
// Draw ring segments covering angles a0..a1 (degrees clockwise from 12 o'clock)
// onto g, whose origin is screen (ox,oy) and size w x h. Off-target segments are skipped.
void ringArc(Adafruit_GFX &g,int ox,int oy,int w,int h,float a0,float a1,const RingGeo &r,RingColorFn color) {
  int i0=max(0,(int)floorf(a0/2)), i1=min(RING_SEGS,(int)ceilf(a1/2));
  for(int i=i0;i<i1;i++) {
    int x0=r.ix[i],y0=r.iy[i],x1=r.ox[i],y1=r.oy[i],x2=r.ox[i+1],y2=r.oy[i+1],x3=r.ix[i+1],y3=r.iy[i+1];
    int minX=min(min(x0,x1),min(x2,x3)), maxX=max(max(x0,x1),max(x2,x3));
    int minY=min(min(y0,y1),min(y2,y3)), maxY=max(max(y0,y1),max(y2,y3));
    if(maxX<ox || minX>=ox+w || maxY<oy || minY>=oy+h) continue;
    uint16_t c=color(i*2+1.0f);
    g.fillTriangle(x0-ox,y0-oy,x1-ox,y1-oy,x2-ox,y2-oy,c);
    g.fillTriangle(x0-ox,y0-oy,x2-ox,y2-oy,x3-ox,y3-oy,c);
  }
}
// Called every face frame before the canvas is copied: the screen-only parts of the
// ring are drawn straight to the LCD, and only where the colors just changed.
void updateRing(uint32_t now) {
  if(sweeping) {
    float t=constrain((now-sweepStart)/(float)RING_MS,0.0f,1.0f); t=t*t*(3-2*t);
    ringHeadNow=t*(360.0f+RING_BAND);
    float from=headDrawn-RING_BAND;
    if(t>=1.0f) sweeping=false;      // remaining segments are now the final color
    if(!ringDirty) ringArc(tft,0,0,240,240,from,sweeping?ringHeadNow:360.0f,OWNER_RING,ringColor);
    headDrawn=ringHeadNow;
  }
  if(ringDirty) { ringArc(tft,0,0,240,240,0,360,OWNER_RING,ringColor); ringDirty=false; }
}

// ----- countdown timer -----
uint16_t cdColor(float a) {
  if(cdState==T_OFF) return C_BLACK;
  const uint8_t *c=mono?PALETTE[0]:PALETTE[cdColorIdx];
  if(cdState==T_ALARM) return alarmOn?rgb(c[0],c[1],c[2]):C_BLACK;
  return a<cdSeg*2.0f ? rgb(c[0]/6,c[1]/6,c[2]/6) : rgb(c[0],c[1],c[2]);
}
void wakeFromIdle(uint32_t now);
void updateCountdown(uint32_t now) {
  if(cdState==T_RUN) {
    int32_t left=(int32_t)(cdEnd-now);
    if(left<=0) { cdState=T_ALARM; alarmStart=now; alarmOn=true; cdDirty=true; wakeFromIdle(now); return; }
    int seg=constrain(RING_SEGS-(int)((uint64_t)left*RING_SEGS/cdTotal),0,RING_SEGS);
    if(seg!=cdSeg) { cdSeg=seg; cdDirty=true; }
  } else if(cdState==T_ALARM) {
    uint32_t t=now-alarmStart;
    if(t>=ALARM_MS) { cdState=T_OFF; cdDirty=true; return; }
    bool on=(t/ALARM_BLINK)%2==0;
    if(on!=alarmOn) { alarmOn=on; cdDirty=true; }
  }
}
// Screen-only parts of the timer ring, redrawn only when they change.
void flushCountdown(const RingGeo &r) {
  if(cdDirty) { ringArc(tft,0,0,240,240,0,360,r,cdColor); cdDirty=false; }
}
void setOwner(int who) {
  if(who==owner) return;             // same AI again: keep the ring (and any sweep) as is
  if(sweeping) ringDirty=true;       // interrupted sweep: repaint everything consistently
  ringFrom=owner; owner=who;
  prefs.putInt("owner",owner);
  if(active>=0 && ringFrom!=owner) { sweeping=true; sweepStart=millis(); headDrawn=0; ringHeadNow=0; }
  else { sweeping=false; ringHeadNow=360.0f+RING_BAND; ringDirty=true; }
}

void saveActive(int slot) {
  // Avoid needless flash writes when the same mode is chosen again.
  if(savedActive!=slot) { prefs.putInt("active",slot); savedActive=slot; }
}
void activate(int slot) {
  if(active<0) {
    const float initial[11]={100,100,0,0,65,0,0,0,0,0,0};
    memcpy(pose.v,initial,sizeof(pose.v));
    for(int i=0;i<3;i++) pose.rgb[i]=255;
    pose.eyes=EYE_NORMAL; pose.fx=0;
  }
  fromPose=pose;
  active=slot; target=0; frameStart=millis();
  tft.fillScreen(GC9A01A_BLACK);
  ringDirty=true; cdDirty=true; noticeSeg=noticeDrawn=-1;
}
void enterClock() {
  active=CLOCK_SCREEN; tft.fillScreen(GC9A01A_BLACK);
  oldHX=oldMX=oldSX=CX; oldHY=oldMY=oldSY=CY; drawClockFace();
  cdDirty=true;
}

// ----- photos -----
void photoPath(char *buf,int id) { snprintf(buf,12,"/p%d.raw",id); }
bool hasPhoto(int id) {
  if(!fsReady || id<0 || id>=MAX_PHOTOS) return false;
  char p[12]; photoPath(p,id); return LittleFS.exists(p);
}
uint32_t photoMask() { uint32_t m=0; for(int i=0;i<MAX_PHOTOS;i++) if(hasPhoto(i)) m|=1u<<i; return m; }
// The next stored photo after <after> (wrapping around), or -1 if there is none.
int nextPhoto(int after) {
  for(int k=1;k<=MAX_PHOTOS;k++) { int id=((after+k)%MAX_PHOTOS+MAX_PHOTOS)%MAX_PHOTOS; if(hasPhoto(id)) return id; }
  return -1;
}
void setCurrentPhoto(int id) { if(id!=currentPhoto) { currentPhoto=id; prefs.putInt("photo",id); } }
void clockNow(int &h,int &m,int &s) {
  unsigned long t=((unsigned long)clockHour*3600UL+clockMinute*60UL+clockSecond+(millis()-clockStartMillis)/1000UL)%86400UL;
  h=t/3600UL; m=(t%3600UL)/60UL; s=t%60UL;
}
// Clock hands drawn over the picture: white with a darkened edge so they read on any photo.
uint16_t shade(uint16_t c) { return (((c>>11)&31)>>2)<<11 | (((c>>5)&63)>>2)<<5 | ((c&31)>>2); }
float handDist(float px,float py,const Hand &h) {
  float dx=h.x1-h.x0, dy=h.y1-h.y0, l=dx*dx+dy*dy;
  float t=l>0?constrain(((px-h.x0)*dx+(py-h.y0)*dy)/l,0.0f,1.0f):0.0f;
  float ex=h.x0+t*dx-px, ey=h.y0+t*dy-py; return sqrtf(ex*ex+ey*ey);
}
void overlayStrip(uint16_t *px,int y0,int rows,const Hand *hd,int n) {
  // hd[n] is the center dot (a zero-length hand). Edges first, then the white bodies.
  for(int pass=0;pass<2;pass++) for(int k=0;k<=n;k++) {
    const Hand &h=hd[k]; float pad=h.w+2.5f;
    int ya=max(y0,(int)floorf(min(h.y0,h.y1)-pad)), yb=min(y0+rows-1,(int)ceilf(max(h.y0,h.y1)+pad));
    int xa=max(0,(int)floorf(min(h.x0,h.x1)-pad)), xb=min(239,(int)ceilf(max(h.x0,h.x1)+pad));
    for(int y=ya;y<=yb;y++) for(int x=xa;x<=xb;x++) {
      float d=handDist(x+0.5f,y+0.5f,h); uint16_t &p=px[(y-y0)*240+x];
      if(pass==0 && d>h.w && d<=h.w+2.0f) p=shade(p);
      if(pass==1 && d<=h.w) p=0xFFFF;
    }
  }
}
// Streams a stored picture to the LCD in strips of 8 rows (no full-frame buffer).
bool drawPhoto(int id) {
  if(!hasPhoto(id)) return false;
  char path[12]; photoPath(path,id);
  File f=LittleFS.open(path,"r");
  if(!f || f.size()!=PHOTO_BYTES) { if(f) f.close(); return false; }
  Hand hd[3]; int n=0;
  if(photoOverlay && clockSynced) {
    int h,m,s; clockNow(h,m,s); lastPhotoMinute=h*60+m;
    float ha=((h%12)+m/60.0f)*30.0f*DEG_TO_RAD, ma=m*6.0f*DEG_TO_RAD;
    hd[0]={(float)CX,(float)CY,CX+55*sinf(ha),CY-55*cosf(ha),3.0f};
    hd[1]={(float)CX,(float)CY,CX+85*sinf(ma),CY-85*cosf(ma),2.0f};
    hd[2]={(float)CX,(float)CY,(float)CX,(float)CY,5.0f};
    n=2;
  }
  const int ROWS=8; uint16_t *strip=(uint16_t*)photoBuf;   // 240*8*2 = 3840 bytes
  for(int y=0;y<240;y+=ROWS) {
    if(f.read(photoBuf,240*ROWS*2)!=240*ROWS*2) break;
    if(n) overlayStrip(strip,y,ROWS,hd,n);
    tft.drawRGBBitmap(0,y,strip,240,ROWS);
  }
  f.close();
  return true;
}
bool showPhotoScreen(int id,bool overlay,bool slides) {
  if(!hasPhoto(id)) return false;
  active=PHOTO_SCREEN; shownPhoto=id; photoOverlay=overlay; slideshow=slides; lastSlide=millis();
  if(!drawPhoto(id)) { enterClock(); return false; }
  if(cdState!=T_OFF) cdDirty=true;
  return true;
}
// Timer on top of a photo uses the outer ring; when it goes away the photo is redrawn.
void flushPhotoCountdown() {
  if(!cdDirty) return;
  if(cdState==T_OFF) drawPhoto(shownPhoto); else ringArc(tft,0,0,240,240,0,360,OWNER_RING,cdColor);
  cdDirty=false;
}
void updatePhotoScreen(uint32_t now) {
  bool redraw=false;
  if(slideshow && now-lastSlide>=(uint32_t)saver[3]*1000UL) {
    lastSlide=now; int nx=nextPhoto(shownPhoto);
    if(nx>=0 && nx!=shownPhoto) { shownPhoto=nx; redraw=true; }
  }
  if(photoOverlay && clockSynced) { int h,m,s; clockNow(h,m,s); if(h*60+m!=lastPhotoMinute) redraw=true; }
  if(redraw) { drawPhoto(shownPhoto); if(cdState!=T_OFF) cdDirty=true; }
  flushPhotoCountdown();
}
// After a failed transfer, throw away whatever is still arriving so the leftover photo
// bytes are not read as commands. Stops once the line has been quiet for 100 ms.
void drainSerial() {
  uint32_t quiet=millis();
  while(millis()-quiet<100) { if(Serial.available()) { Serial.read(); quiet=millis(); } else delay(1); }
}
void photoFail(const char *reply) {
  if(photoIn) photoIn.close();
  LittleFS.remove(PHOTO_TMP);
  drainSerial(); lineLength=0; overflow=false;
  Serial.println(reply);
}
// Shown on purpose (app or AI), like the clock: no saver until the next face arrives.
void showChosenPhoto(int id) {
  if(!showPhotoScreen(id,false,false)) { Serial.println(fsReady?"ERR NOPHOTO":"ERR FS"); return; }
  setCurrentPhoto(id); saveActive(PHOTO_SCREEN); idleArmed=false;
  Serial.println("OK PHOTO");
}
void photoCommand(char *line) {
  unsigned long a; int id, n=0;
  if(sscanf(line,"PHOTO:BEGIN:%d:%lu%n",&id,&a,&n)==2 && !line[n] && id>=0 && id<MAX_PHOTOS && a==PHOTO_BYTES) {
    if(!fsReady) { Serial.println("ERR FS"); return; }
    if(photoIn) photoIn.close();
    LittleFS.remove(PHOTO_TMP);
    if(LittleFS.usedBytes()+PHOTO_BYTES+8192>LittleFS.totalBytes()) { Serial.println("ERR FULL"); return; }
    photoIn=LittleFS.open(PHOTO_TMP,"w"); photoGot=0; photoSum=0; photoInId=id;
    Serial.println(photoIn?"OK PHOTO":"ERR FS"); return;
  }
  n=0;
  if(sscanf(line,"PHOTO:DATA:%lu%n",&a,&n)==1 && !line[n] && a>=1 && a<=PHOTO_CHUNK) {
    // The n raw bytes follow the line right away; always consume them, even on error.
    size_t got=Serial.readBytes((char*)photoBuf,a);
    if(!photoIn || got!=a || photoGot+a>PHOTO_BYTES) { photoFail("ERR DATA"); return; }
    for(uint32_t i=0;i<a;i++) photoSum=photoSum*31u+photoBuf[i];
    if(photoIn.write(photoBuf,a)!=a) { photoFail("ERR FS"); return; }
    photoGot+=a; Serial.println("OK DATA"); return;
  }
  n=0;
  if(sscanf(line,"PHOTO:END:%lu%n",&a,&n)==1 && !line[n]) {
    if(!photoIn) { Serial.println("ERR DATA"); return; }
    photoIn.close();
    if(photoGot!=PHOTO_BYTES || photoSum!=a) { photoFail("ERR DATA"); return; }
    char path[12]; photoPath(path,photoInId);
    LittleFS.remove(path);
    if(!LittleFS.rename(PHOTO_TMP,path)) { Serial.println("ERR FS"); return; }
    showChosenPhoto(photoInId); return;
  }
  if(!strcmp(line,"PHOTO:SHOW")) { showChosenPhoto(hasPhoto(currentPhoto)?currentPhoto:nextPhoto(-1)); return; }
  n=0;
  if(sscanf(line,"PHOTO:SHOW:%d%n",&id,&n)==1 && !line[n]) { showChosenPhoto(id); return; }
  n=0;
  if(sscanf(line,"PHOTO:DEL:%d%n",&id,&n)==1 && !line[n] && id>=0 && id<MAX_PHOTOS) {
    char path[12]; photoPath(path,id);
    if(fsReady) LittleFS.remove(path);
    if(currentPhoto==id) setCurrentPhoto(nextPhoto(id));
    if(active==PHOTO_SCREEN && shownPhoto==id) {
      int nx=nextPhoto(id);
      if(nx<0 || !showPhotoScreen(nx,photoOverlay,slideshow)) { enterClock(); if(savedActive==PHOTO_SCREEN) saveActive(CLOCK_SCREEN); }
    }
    Serial.println("OK PHOTO"); return;
  }
  if(!strcmp(line,"PHOTO:LIST")) {
    Serial.printf("OK LIST:%lu:%d\r\n",(unsigned long)photoMask(),hasPhoto(currentPhoto)?currentPhoto:-1); return;
  }
  Serial.println("ERR COMMAND");
}

// ----- campfire -----
// Pixel-art campfire: a 52x52 grid of 4x4-pixel cells inside the round screen. The flames
// are a heat field: each cell takes the average of the cells below it, cools a little at
// random and is squeezed toward the middle higher up. Drawn in a small fire palette over
// crossed logs, with a flickering ground glow, rising sparks and twinkling stars.
const int FG=52, FH=40, FCELL=4, FOX=16, FOY=16;    // grid size, fire rows, cell px, origin
const int FIRE_MAX=36, FIRE_MS=70;                   // heat range, frame time (~14 fps)
uint8_t fireHeat[FH*FG];
uint16_t fireBack[FG*FG];       // sky, stars, ground (without glow)
uint8_t fireGlowW[FG*FG];       // how much the ground is lit by the fire (0-255)
uint8_t fireLog[FG*FG];         // 0 none, 1 bark edge, 2 bark, 3 cut end, 4 end ring
int8_t fireSpan[FG][2];         // first/last cell inside the circle on each grid row
struct Spark { float x,y; uint8_t life,hot; };
Spark sparks[10];
uint32_t fireRng=0x9E3779B9u, lastFire=0;
bool fireReady=false;
// Dark red -> red -> orange -> yellow -> pale yellow -> white.
const uint8_t FIRE_PAL[9][3]={{110,16,16},{160,28,12},{206,52,12},{238,90,16},{250,130,24},
                              {255,168,40},{255,206,70},{255,236,140},{255,250,214}};
uint32_t fireRand() { fireRng^=fireRng<<13; fireRng^=fireRng>>17; fireRng^=fireRng<<5; return fireRng; }
uint16_t mix565(int r,int g,int b,int r2,int g2,int b2,int w) {   // w 0-255 toward the second color
  return rgb(r+((r2-r)*w>>8),g+((g2-g)*w>>8),b+((b2-b)*w>>8));
}
void fireLogLine(float x0,float y0,float x1,float y1) {
  // A log 3 cells thick, outlined, with a light cut end at both ends.
  for(int cy=0;cy<FG;cy++) for(int cx=0;cx<FG;cx++) {
    float dx=x1-x0, dy=y1-y0, l=dx*dx+dy*dy, t=constrain(((cx-x0)*dx+(cy-y0)*dy)/l,0.0f,1.0f);
    float ex=x0+t*dx-cx, ey=y0+t*dy-cy, d=sqrtf(ex*ex+ey*ey);
    if(d>1.6f) continue;
    uint8_t v=d>1.0f?1:2;
    if(t<=0.0f || t>=1.0f) v=d<0.6f?4:3;
    if(v>fireLog[cy*FG+cx] || fireLog[cy*FG+cx]==1) fireLog[cy*FG+cx]=v;
  }
}
void fireInit() {
  memset(fireHeat,0,sizeof(fireHeat)); memset(fireLog,0,sizeof(fireLog));
  for(int cy=0;cy<FG;cy++) {
    fireSpan[cy][0]=FG; fireSpan[cy][1]=-1;
    for(int cx=0;cx<FG;cx++) {
      float px=FOX+cx*FCELL+2-CX, py=FOY+cy*FCELL+2-CY, r=sqrtf(px*px+py*py);
      if(r<=101) { if(fireSpan[cy][0]==FG) fireSpan[cy][0]=cx; fireSpan[cy][1]=cx; }
      // Night sky getting lighter toward the horizon, then dark ground.
      fireBack[cy*FG+cx]= cy<41 ? rgb(8+cy/3,10+cy/4,26+cy/3) : rgb(30-(cy-41),20-(cy-41)/2,18-(cy-41)/2);
      float gx=(cx-25.5f)/19.0f, gy=(cy-43.0f)/7.0f, g=1.0f-sqrtf(gx*gx+gy*gy);
      fireGlowW[cy*FG+cx]= cy>=41 && g>0 ? (uint8_t)(min(1.0f,g*1.4f)*150) : 0;
    }
  }
  const uint8_t stars[][2]={{9,9},{16,4},{30,6},{40,11},{45,18},{7,20},{22,12},{36,3},{12,28},{43,27}};
  for(auto &st:stars) fireBack[st[1]*FG+st[0]]=rgb(150,160,200);
  fireLogLine(14,46,34,38); fireLogLine(18,38,38,46);
  for(auto &sp:sparks) sp.life=0;
  fireReady=true;
}
void fireStep() {
  // Fuel row: hottest in the middle, flickering.
  for(int x=0;x<FG;x++) {
    float d=fabsf(x-25.5f)/9.5f;
    int h=d<1 ? (int)(FIRE_MAX*(1.0f-0.35f*d*d)) - (int)(fireRand()%9) + ((fireRand()&15)==0 ? 6 : 0) : 0;
    fireHeat[(FH-1)*FG+x]=constrain(h,0,FIRE_MAX);
  }
  // Heat rises one row with a random sideways drift (this makes the flame tongues) and
  // cools a little at random; blending with the previous frame keeps it from looking grainy.
  // Cooling grows away from the middle (narrower higher up) and near the top (tips).
  for(int y=1;y<FH;y++) for(int x=0;x<FG;x++) {
    int p=fireHeat[y*FG+x];
    uint32_t r=fireRand();
    int nx=constrain(x+(int)(r%3)-1,0,FG-1);
    int half=2+(y*8)/FH, off=abs(nx*2-51)/2;
    int cool=(r>>3)&1;
    if(off>half) cool+=1+((r>>5)&1);
    if(y<13) cool+=((r>>7)%3)==0;
    int h=p>cool ? p-cool : 0;
    uint8_t &d=fireHeat[(y-1)*FG+nx];
    d=(h*3+d)/4;
  }
  // Sparks: born at the fire, float up with a wobble, fade.
  for(auto &sp:sparks) {
    if(sp.life) { sp.y-=0.55f; sp.x+=((int)(fireRand()%3)-1)*0.4f; sp.life--; continue; }
    if(fireRand()%24==0) { sp.x=19+fireRand()%14; sp.y=24+fireRand()%8; sp.life=12+fireRand()%18; sp.hot=fireRand()&1; }
  }
  if(fireRand()%6==0) {   // a star twinkles
    const uint8_t stars[][2]={{9,9},{16,4},{30,6},{40,11},{45,18},{7,20},{22,12},{36,3},{12,28},{43,27}};
    int k=fireRand()%10; fireBack[stars[k][1]*FG+stars[k][0]]= fireRand()&1 ? rgb(150,160,200) : rgb(70,80,120);
  }
}
uint16_t fireCell(int cx,int cy,int flick) {
  uint8_t lg=fireLog[cy*FG+cx];
  if(lg) {   // logs in front of the flames, lit from above
    int lit=cy<41 ? 40 : 0;
    switch(lg) {
      case 1: return rgb(34,18,12);
      case 2: return rgb(96+lit,54+lit/3,28);
      case 3: return rgb(214,160,98);
      default: return rgb(150,96,52);
    }
  }
  if(cy<FH) {
    int h=fireHeat[cy*FG+cx];
    if(h>=5) { const uint8_t *c=FIRE_PAL[min(8,(h-5)*9/(FIRE_MAX-4))]; return rgb(c[0],c[1],c[2]); }
  }
  for(auto &sp:sparks) if(sp.life && (int)sp.x==cx && (int)sp.y==cy) return sp.hot&&sp.life>8 ? rgb(255,220,120) : rgb(240,120,40);
  uint16_t b=fireBack[cy*FG+cx]; uint8_t w=fireGlowW[cy*FG+cx];
  if(!w) return b;
  int r=(b>>11)<<3, g=((b>>5)&63)<<2, bl=(b&31)<<3;
  return mix565(r,g,bl,150,70,24,(w*flick)>>8);
}
void drawFire() {
  int flick=170+(int)(fireRand()%60);
  uint16_t *row=(uint16_t*)photoBuf;   // one grid row: up to 52 cells x 4 x 4 px = 1664 bytes
  for(int cy=0;cy<FG;cy++) {
    int a=fireSpan[cy][0], b=fireSpan[cy][1];
    if(b<a) continue;
    int w=(b-a+1)*FCELL;
    for(int cx=a;cx<=b;cx++) {
      uint16_t c=fireCell(cx,cy,flick);
      for(int k=0;k<FCELL;k++) row[(cx-a)*FCELL+k]=c;
    }
    for(int k=1;k<FCELL;k++) memcpy(row+k*w,row,w*2);
    tft.drawRGBBitmap(FOX+a*FCELL,FOY+cy*FCELL,row,w,FCELL);
  }
}
void enterFire() {
  if(!fireReady) fireInit();
  active=FIRE_SCREEN; tft.fillScreen(GC9A01A_BLACK);
  for(int i=0;i<30;i++) fireStep();   // start with flames already up
  lastFire=0; cdDirty=true;
}
void updateFire(uint32_t now) {
  if(now-lastFire>=FIRE_MS) { lastFire=now; fireStep(); drawFire(); }
  flushCountdown(OWNER_RING);         // the fire stays inside r 101, the timer uses the edge
}

// ----- screen saver -----
// A face chosen with PLAY (by the app or an AI) restarts the saver countdown.
void armIdle(int slot,uint32_t now) { chosenSlot=slot; idleStart=now; idleStage=0; idleArmed=true; }
// Back to the chosen face if the saver is showing.
void wakeFromIdle(uint32_t now) {
  if(!idleArmed) return;
  if(idleStage>0 && chosenSlot>=0 && validMode(modes[chosenSlot]) && active!=chosenSlot) activate(chosenSlot);
  idleStage=0; idleStart=now;
}
void startSaver() {
  bool overlay=saver[2]!=0;
  if(saver[1]==SV_CLOCK && clockSynced) { enterClock(); return; }   // never show an unset clock
  if(saver[1]==SV_FIRE) { enterFire(); return; }
  if(saver[1]==SV_PHOTO || saver[1]==SV_SLIDES) {
    int id=hasPhoto(currentPhoto)?currentPhoto:nextPhoto(-1);
    if(id>=0 && showPhotoScreen(id,overlay,saver[1]==SV_SLIDES)) return;
  }
  // Sleep saver, and the fallback when there is no clock time or no photo yet.
  if(validMode(modes[SLEEPY_SLOT]) && active!=SLEEPY_SLOT) activate(SLEEPY_SLOT);
}
// ----- saver notice -----
uint16_t noticeColor(float a) {
  if(noticeSeg<0) return C_BLACK;
  if(mono) return a<noticeSeg*2.0f ? rgb(200,200,200) : rgb(40,40,40);
  return a<noticeSeg*2.0f ? rgb(190,140,255) : rgb(36,28,52);   // filled part bright, rest a dim track
}
void updateNotice(uint32_t now) {
  int seg=-1;
  // Only on a face, only while the countdown runs, and never on top of a running timer.
  if(active>=0 && idleArmed && idleStage==0 && saver[1]!=SV_OFF && saver[0]>0 && cdState==T_OFF) {
    int32_t left=saver[0]*1000-(int32_t)(now-idleStart);
    if(left>0 && left<=NOTICE_MS) seg=constrain(RING_SEGS-(int)((int64_t)left*RING_SEGS/NOTICE_MS),0,RING_SEGS);
  }
  noticeSeg=seg;
}
// Screen-only parts: the whole ring when it appears or goes away, else just the new segments.
void flushNotice() {
  if(noticeSeg==noticeDrawn) return;
  if(noticeSeg<0 || noticeDrawn<0 || noticeSeg<noticeDrawn) {
    ringArc(tft,0,0,240,240,0,360,TIMER_RING,noticeColor);
    if(noticeSeg<0) cdDirty=true;   // gone: let a timer that may have started repaint its ring
  } else {
    ringArc(tft,0,0,240,240,noticeDrawn*2.0f,noticeSeg*2.0f,TIMER_RING,noticeColor);
  }
  noticeDrawn=noticeSeg;
}
void updateIdle(uint32_t now) {
  if(!idleArmed || saver[1]==SV_OFF || saver[0]<=0 || now-lastIdleCheck<500) return;
  lastIdleCheck=now;
  uint32_t secs=(now-idleStart)/1000;
  if(idleStage==0 && secs>=(uint32_t)saver[0]) { idleStage=1; startSaver(); }
  else if(idleStage==1 && active==SLEEPY_SLOT && secs>=2u*(uint32_t)saver[0]) {
    idleStage=2;
    if(validMode(modes[SLEEPING_SLOT])) activate(SLEEPING_SLOT);
  }
}

// Checksum of a stored slot, so the Mac can skip re-sending identical idle faces.
uint32_t modeSum(const Mode &m) {
  if(!validMode(m)) return 0;
  uint32_t s=m.count;
  for(uint32_t i=0;i<m.count;i++) for(int j=0;j<F_COUNT;j++) s=s*31u+(uint32_t)(m.frames[i].v[j]+20000);
  return s;
}

// ----- drawing helpers in screen coordinates -----
void sRect(int x,int y,int w,int h,uint16_t c) { canvas.fillRect(x-OX,y-OY,w,h,c); }
void sRound(int x,int y,int w,int h,int r,uint16_t c) { canvas.fillRoundRect(x-OX,y-OY,w,h,r,c); }
void sCircle(int x,int y,int r,uint16_t c) { canvas.fillCircle(x-OX,y-OY,r,c); }
void sTri(int x0,int y0,int x1,int y1,int x2,int y2,uint16_t c) { canvas.fillTriangle(x0-OX,y0-OY,x1-OX,y1-OY,x2-OX,y2-OY,c); }
void sLine(int x0,int y0,int x1,int y1,uint16_t c) { canvas.drawLine(x0-OX,y0-OY,x1-OX,y1-OY,c); }
void sThick(int x0,int y0,int x1,int y1,int t,uint16_t c) { for(int k=0;k<t;k++) sLine(x0,y0+k,x1,y1+k,c); }
void sText(int x,int y,char ch,uint16_t c) {
  canvas.setTextSize(3); canvas.setTextColor(c); canvas.setCursor(x-OX,y-OY); canvas.print(ch);
}
void heart(int x,int y,float s,uint16_t c) {
  int r=max(2,(int)roundf(6*s)), dx=(int)roundf(5*s), dy=(int)roundf(4*s);
  sCircle(x-dx,y-dy,r,c); sCircle(x+dx,y-dy,r,c);
  sTri(x-(int)roundf(11*s),y-(int)roundf(2*s),x+(int)roundf(11*s),y-(int)roundf(2*s),x,y+(int)roundf(11*s),c);
}
void drop(int x,int y,uint16_t c) { sCircle(x,y,4,c); sTri(x-4,y-1,x+4,y-1,x,y-9,c); }
void star(int x,int y,int len,uint16_t c) {
  sTri(x,y-len,x-2,y,x+2,y,c); sTri(x,y+len,x-2,y,x+2,y,c);
  sTri(x-len,y,x,y-2,x,y+2,c); sTri(x+len,y,x,y-2,x,y+2,c);
}
float phase(uint32_t now,float period,float offset) { return fmodf(now/period+offset,1.0f); }
// A round-ended stroke of radius r (for fingers).
void sStroke(float x0,float y0,float x1,float y1,int r,uint16_t c) {
  float dx=x1-x0, dy=y1-y0; int n=max(1,(int)(sqrtf(dx*dx+dy*dy)/2));
  for(int k=0;k<=n;k++) sCircle((int)roundf(x0+dx*k/n),(int)roundf(y0+dy*k/n),r,c);
}
// Waving hand at the right of the face: palm plus four fingers and a thumb, rocking.
void waveHand(uint32_t now,uint16_t c) {
  float hx=188, hy=150, rock=0.45f*sinf(now/150.0f);
  const float spread[4]={-0.42f,-0.14f,0.14f,0.42f}, len[4]={12,14,14,12};
  for(int k=0;k<4;k++) {
    float a=rock+spread[k];
    sStroke(hx+sinf(a)*6,hy-cosf(a)*6,hx+sinf(a)*(6+len[k]),hy-cosf(a)*(6+len[k]),2,c);
  }
  float ta=rock-1.25f;
  sStroke(hx+sinf(ta)*5,hy-cosf(ta)*5,hx+sinf(ta)*14,hy-cosf(ta)*14,2,c);
  sCircle((int)hx,(int)hy,8,c);
}
// Light bulb above the right eye, its rays pulsing.
void bulb(uint32_t now) {
  int bx=190, by=60;   // inside the face canvas (it starts at y 30)
  uint16_t glass=rgb(255,225,90), base=rgb(170,170,170);
  float pulse=0.5f+0.5f*sinf(now/180.0f);
  for(int k=0;k<5;k++) {
    float a=(-60+k*30)*DEG_TO_RAD, r0=13, r1=17+3*pulse;
    sStroke(bx+sinf(a)*r0,by-cosf(a)*r0,bx+sinf(a)*r1,by-cosf(a)*r1,1,glass);
  }
  sCircle(bx,by,9,glass);
  sRect(bx-5,by+7,10,7,base);
  sRect(bx-5,by+9,10,1,C_BLACK); sRect(bx-5,by+12,10,1,C_BLACK);
}
// Two hands pressed together under the mouth (hoping, praying), bobbing a little.
void prayHands(uint32_t now,uint16_t c) {
  int y=(int)roundf(2*sinf(now/260.0f));
  sStroke(110,203+y,118,180+y,5,c); sStroke(130,203+y,122,180+y,5,c);   // two palms leaning in
  sLine(120,178+y,120,208+y,C_BLACK);                                     // the gap between them
}

void drawEye(int e,float open,int shape,int ex,int ey,uint16_t col,uint32_t now) {
  if(shape!=EYE_NORMAL && open<20) { sRound(ex-11,ey-2,22,4,2,col); return; }
  switch(shape) {
    case EYE_NORMAL: { int h=max(2,(int)roundf(15*open/100)); sRound(ex-10,ey-h,20,h*2,min(9,h),col); break; }
    case EYE_HAPPY: for(int dx=-11;dx<=11;dx++){ float u=dx/11.0f; sRect(ex+dx,ey+3-(int)roundf(9*(1-u*u)),1,4,col);} break;
    case EYE_CALM:  for(int dx=-11;dx<=11;dx++){ float u=dx/11.0f; sRect(ex+dx,ey-5+(int)roundf(9*(1-u*u)),1,4,col);} break;
    case EYE_CROSS: for(int k=-1;k<=1;k++){ sLine(ex-10+k,ey-10,ex+10+k,ey+10,col); sLine(ex+10+k,ey-10,ex-10+k,ey+10,col);} break;
    case EYE_HEART: heart(ex,ey,1.0f,rgb(255,70,120)); break;
    case EYE_SPIRAL: { float rot=now/180.0f; for(float a=0;a<12.5f;a+=0.25f){ float r=a*1.05f;
        sRect(ex+(int)roundf(cosf(a+rot)*r)-1,ey+(int)roundf(sinf(a+rot)*r)-1,2,2,col);} break; }
    case EYE_STAR: star(ex,ey,13,col); sTri(ex-4,ey,ex,ey-4,ex+4,ey,col); sTri(ex-4,ey,ex,ey+4,ex+4,ey,col); break;
    case EYE_DOT: sCircle(ex,ey,4,col); break;
    case EYE_BIG: sCircle(ex,ey,13,col); sCircle(ex+4,ey-5,4,C_BLACK); sCircle(ex-5,ey+5,2,C_BLACK); break;
    case EYE_SQUEEZE: { int d=e==0?1:-1, tip=ex+7*d, back=ex-7*d;
        for(int k=-1;k<=1;k++){ sLine(back,ey-8+k,tip,ey+k,col); sLine(tip,ey+k,back,ey+8+k,col);} break; }
  }
}

void renderFace(const Pose &p,uint32_t now) {
  uint16_t col=rgb((int)p.rgb[0],(int)p.rgb[1],(int)p.rgb[2]);
  int sx=(int)roundf(p.v[P_SHAKE]*sinf(now*0.071f)), sy=(int)roundf(p.v[P_SHAKE]*0.6f*cosf(now*0.093f));
  int ex[2], ey=90+(int)p.v[P_Y]+sy;
  for(int e=0;e<2;e++) ex[e]=80+80*e+(int)p.v[P_X]+sx;
  if(p.fx&FX_BLUSH) for(int e=0;e<2;e++) sRound(ex[e]-13,ey+17,26,8,4,rgb(240,100,140));
  for(int e=0;e<2;e++) drawEye(e,p.v[P_LEFT+e],p.eyes,ex[e],ey,col,now);
  if(p.v[P_LIFT]>=0.5f) {
    float bY=ey-14-p.v[P_LIFT]*1.5f, d=p.v[P_BROW]*0.6f;
    for(int e=0;e<2;e++) {
      int outer=e==0?ex[e]-11:ex[e]+11, inner=e==0?ex[e]+11:ex[e]-11;
      sThick(outer,(int)roundf(bY+d),inner,(int)roundf(bY-d),4,col);
    }
  }
  int w=max(5,(int)p.v[P_WIDTH]/2), mx=120+(int)(p.v[P_X]*0.3f)+sx;
  for(int x=-w;x<=w;x++) {
    float u=(float)x/w, curve=1-u*u;
    int y=142+sy+(int)(p.v[P_SMILE]*curve-p.v[P_TILT]*(u+1)*0.5f);
    int opening=(int)(p.v[P_OPEN]*curve);
    sRect(mx+x,y-opening/2-2,1,opening+5,col);
  }
  uint16_t water=rgb(90,170,255), gold=rgb(255,235,140);
  if(p.fx&FX_TEAR) for(int e=0;e<2;e++) {
    float q=phase(now,1500,e*0.5f); drop(e==0?ex[0]-7:ex[1]+7,ey+12+(int)(q*34),water);
  }
  if(p.fx&FX_SWEAT) drop(186,70+(int)(phase(now,2200,0)*10),water);
  if(p.fx&FX_ZZZ) for(int i=0;i<3;i++) {
    float q=phase(now,2400,i/3.0f); int zx=160+(int)(q*30), zy=88-(int)(q*42), s=5+(int)(q*6);
    sThick(zx-s,zy-s,zx+s,zy-s,2,col); sThick(zx+s,zy-s,zx-s,zy+s,2,col); sThick(zx-s,zy+s,zx+s,zy+s,2,col);
  }
  if(p.fx&FX_HEARTS) for(int i=0;i<2;i++) {
    float q=phase(now,2000,i*0.5f); heart(i?182:58,95-(int)(q*45),0.5f+q*0.3f,rgb(255,90,140));
  }
  if(p.fx&FX_ANGER) {
    float s=1+0.25f*sinf(now/120.0f); int cx=178, cy=52, a=(int)roundf(3*s), b=(int)roundf(9*s);
    uint16_t red=rgb(255,50,50);
    for(int qx=-1;qx<=1;qx+=2) for(int qy=-1;qy<=1;qy+=2) {
      // One bracket per corner: together they form the cartoon "vein" mark.
      int bx=cx+qx*a-(qx>0?0:2), by=cy+qy*a-(qy>0?0:2);
      sRect(bx,min(cy+qy*a,cy+qy*b),2,b-a,red);
      sRect(min(cx+qx*a,cx+qx*b),by,b-a,2,red);
    }
  }
  int bob=(int)roundf(3*sinf(now/300.0f));
  if(p.fx&FX_QUESTION) sText(178,38+bob,'?',col);
  if(p.fx&FX_EXCLAIM) sText(p.fx&FX_QUESTION?156:182,38-bob,'!',rgb(255,215,60));
  if(p.fx&FX_SPARKLE) {
    const int pts[3][2]={{52,58},{192,100},{62,172}};
    for(int i=0;i<3;i++) star(pts[i][0],pts[i][1],3+(int)roundf(4*fabsf(sinf(now/250.0f+i*2))),gold);
  }
  if(p.fx&FX_NOTE) for(int i=0;i<2;i++) {
    float q=phase(now,1800,i*0.5f); int nx=i?184:54, ny=82-(int)(q*30);
    sCircle(nx,ny,4,col); sRect(nx+3,ny-14,2,14,col); sThick(nx+4,ny-14,nx+9,ny-9,2,col);
  }
  if(p.fx&FX_WAVE) waveHand(now,col);
  if(p.fx&FX_BULB) bulb(now);
  if(p.fx&FX_PRAY) prayHands(now,col);
}
// Monochrome style: the face canvas in grays (luminance) just before it goes to the LCD.
void toGray(uint16_t *px,int n) {
  for(int i=0;i<n;i++) {
    uint16_t c=px[i]; int r=(c>>11)<<3, g=((c>>5)&63)<<2, b=(c&31)<<3;
    int y=(r*77+g*150+b*29)>>8; px[i]=rgb(y,y,y);
  }
}

void drawFace() {
  uint32_t now=millis();
  if(now-lastDraw<40 || !canvas.getBuffer()) return;
  lastDraw=now;
  Frame &f=modes[active].frames[target];
  uint32_t elapsed=now-frameStart;
  float t=constrain(elapsed/(float)f.v[F_MOVE],0.0f,1.0f); t=t*t*(3-2*t);
  for(int i=0;i<11;i++) pose.v[i]=fromPose.v[i]+(f.v[CONT[i]]-fromPose.v[i])*t;
  for(int i=0;i<3;i++) pose.rgb[i]=fromPose.rgb[i]+(PALETTE[f.v[F_COLOR]][i]-fromPose.rgb[i])*t;
  // Shapes and effects switch halfway through the transition.
  pose.eyes=t<0.5f?fromPose.eyes:f.v[F_EYES];
  pose.fx=t<0.5f?fromPose.fx:f.v[F_FX];
  if(elapsed >= (uint32_t)(f.v[F_MOVE]+f.v[F_HOLD])) {
    fromPose=pose;
    target=(target+1)%modes[active].count; frameStart=now;
  }
  updateRing(now);
  flushNotice();
  flushCountdown(TIMER_RING);
  canvas.fillScreen(C_BLACK);
  renderFace(pose,now);
  // Ring corners that fall inside the face canvas.
  ringArc(canvas,OX,OY,CW,CH,0,360,OWNER_RING,ringColor);
  if(cdState!=T_OFF) ringArc(canvas,OX,OY,CW,CH,0,360,TIMER_RING,cdColor);
  else if(noticeSeg>=0) ringArc(canvas,OX,OY,CW,CH,0,360,TIMER_RING,noticeColor);
  if(mono) toGray(canvas.getBuffer(),CW*CH);
  tft.drawRGBBitmap(OX,OY,canvas.getBuffer(),CW,CH);
}

void command(char *line) {
  if(!strcmp(line,"HELLO")) { Serial.println("OK FACE8"); return; }
  if(!strncmp(line,"PHOTO:",6)) { photoCommand(line); return; }
  if(!strcmp(line,"FIRE")) {
    // Chosen on purpose, like the clock: no saver until the next face arrives.
    enterFire(); saveActive(FIRE_SCREEN); idleArmed=false;
    Serial.println("OK FIRE"); return;
  }
  if(!strcmp(line,"CLOCK")) {
    // Chosen on purpose, so idling stops here (the clock is already the last stage).
    enterClock(); saveActive(-1); idleArmed=false;
    Serial.println("OK CLOCK"); return;
  }
  int h,m,s,n=0;
  if(sscanf(line,"TIME:%d:%d:%d%n",&h,&m,&s,&n)==3 && !line[n] && h>=0 && h<24 && m>=0 && m<60 && s>=0 && s<60) {
    clockHour=h;clockMinute=m;clockSecond=s;clockStartMillis=millis();clockSynced=true;Serial.println("OK TIME");return;
  }
  n=0;
  if(sscanf(line,"TIMER:%d:%d:%d%n",&h,&m,&s,&n)==3 && !line[n] && h>=0 && m>=h && m<=86400 && s>=0 && s<8) {
    if(h==0) { if(cdState!=T_OFF) { cdState=T_OFF; cdDirty=true; } }
    else {
      cdState=T_RUN; cdTotal=(uint32_t)m*1000UL; cdEnd=millis()+(uint32_t)h*1000UL;
      cdColorIdx=s; cdSeg=-1; cdDirty=true;
    }
    Serial.println("OK TIMER"); return;
  }
  n=0;
  int t,o,sl; n=0;
  if(sscanf(line,"SAVER:%d:%d:%d:%d%n",&h,&t,&o,&sl,&n)==4 && !line[n] && h>=0 && h<=86400 && t>=0 && t<SV_COUNT
     && o>=0 && o<=1 && sl>=5 && sl<=86400) {
    int32_t next[4]={h,t,o,sl};
    if(memcmp(next,saver,sizeof(next))) { memcpy(saver,next,sizeof(next)); prefs.putBytes("saver",saver,sizeof(saver)); }
    Serial.println("OK SAVER"); return;
  }
  int slot,count; n=0;
  if(sscanf(line,"SUM:%d%n",&slot,&n)==1 && !line[n] && slot>=0 && slot<SLOTS) {
    Serial.printf("OK SUM:%lu\r\n",(unsigned long)modeSum(modes[slot])); return;
  }
  n=0;
  if(sscanf(line,"BEGIN:%d:%d%n",&slot,&count,&n)==2 && !line[n] && slot>=0 && slot<SLOTS && count>=1 && count<=24) {
    memset(&staging,0,sizeof(staging));staging.version=MODE_VERSION;staging.count=count;
    uploadSlot=slot;received=0;Serial.println("OK BEGIN");return;
  }
  if(!strncmp(line,"FRAME:",6)) {
    Frame f; char *cursor=line+6; bool valid=true;
    for(int i=0;i<F_COUNT;i++) {
      char *end; long value=strtol(cursor,&end,10);
      if(end==cursor || value < -10000 || value > 10000 || (i<F_COUNT-1 ? *end!=',' : *end!='\0')) { valid=false;break; }
      f.v[i]=(int16_t)value;cursor=end+1;
    }
    if(uploadSlot<0 || !valid || !validFrame(f) || received>=(int)staging.count) {
      uploadSlot=-1;Serial.println("ERR FRAME");return;
    }
    staging.frames[received++]=f;Serial.println("OK FRAME");return;
  }
  if(!strcmp(line,"COMMIT")) {
    if(uploadSlot<0 || received!=(int)staging.count || !validMode(staging)) {Serial.println("ERR INCOMPLETE");return;}
    // Skip the flash write when the slot already holds identical data.
    if(memcmp(&modes[uploadSlot],&staging,sizeof(staging))!=0) {
      char key[8];snprintf(key,sizeof(key),"mode%d",uploadSlot);
      if(prefs.putBytes(key,&staging,sizeof(staging))!=sizeof(staging)) {Serial.println("ERR SAVE");return;}
      modes[uploadSlot]=staging;
      if(active==uploadSlot) activate(uploadSlot);
    }
    uploadSlot=-1;Serial.println("OK COMMIT");return;
  }
  n=0;
  if(sscanf(line,"STYLE:%d%n",&slot,&n)==1 && !line[n] && slot>=0 && slot<=1) {
    bool next=slot==1;
    if(next!=mono) {
      mono=next; prefs.putBool("mono",mono);
      ringDirty=true; cdDirty=true; noticeDrawn=-1;
      if(active==FIRE_SCREEN || active==PHOTO_SCREEN || active==CLOCK_SCREEN) cdDirty=true;
    }
    Serial.println("OK STYLE"); return;
  }
  n=0;
  if(sscanf(line,"OWNER:%d%n",&slot,&n)==1 && !line[n] && slot>=0 && slot<3) {
    setOwner(slot); Serial.println("OK OWNER"); return;
  }
  n=0;
  if(sscanf(line,"PLAY:%d%n",&slot,&n)==1 && !line[n] && slot>=0 && slot<SLOTS && validMode(modes[slot])) {
    if(active!=slot) activate(slot);
    armIdle(slot,millis());
    saveActive(slot);Serial.println("OK PLAY");return;
  }
  Serial.println("ERR COMMAND");
}
void setup() {
  // USB CDC drops bytes when its receive buffer overflows (no flow control), so make it
  // hold a whole photo chunk plus its header line while a face frame is being drawn.
  Serial.setRxBufferSize(16384);
  Serial.begin(115200);SPI.begin(TFT_SCK,-1,TFT_MOSI,TFT_CS);
  tft.begin();tft.setRotation(0);tft.fillScreen(GC9A01A_BLACK);
  prefs.begin("face-engine",false);
  // Uses the "spiffs" data partition of the default partition scheme (formatted on first use).
  fsReady=LittleFS.begin(true);
  initRing(OWNER_RING,RING_IN,RING_OUT);
  initRing(TIMER_RING,104,110);
  owner=constrain(prefs.getInt("owner",0),0,2); ringFrom=owner;
  mono=prefs.getBool("mono",false);
  if(prefs.getBytesLength("saver")==sizeof(saver)) {
    int32_t v[4]; prefs.getBytes("saver",v,sizeof(v));
    if(v[0]>=0 && v[0]<=86400 && v[1]>=0 && v[1]<SV_COUNT && v[2]>=0 && v[2]<=1 && v[3]>=5 && v[3]<=86400) memcpy(saver,v,sizeof(v));
  }
  if(prefs.isKey("idle")) prefs.remove("idle");   // FACE5/6 idle stages, replaced by the saver
  // FACE6 kept a single /photo.raw; it becomes photo 0.
  if(fsReady && LittleFS.exists("/photo.raw") && !LittleFS.exists("/p0.raw")) LittleFS.rename("/photo.raw","/p0.raw");
  currentPhoto=prefs.getInt("photo",-1);
  if(!hasPhoto(currentPhoto)) currentPhoto=nextPhoto(-1);
  for(int i=0;i<SLOTS;i++) {
    char key[8];snprintf(key,sizeof(key),"mode%d",i);
    size_t length=prefs.getBytesLength(key);
    if(length==sizeof(Mode)) prefs.getBytes(key,&modes[i],sizeof(Mode));
    if(!validMode(modes[i])) {
      memset(&modes[i],0,sizeof(Mode));
      if(length) prefs.remove(key);  // free space held by old FACE2 data
    }
  }
  int saved=prefs.getInt("active",-1); savedActive=saved;
  if(saved>=0 && saved<SLOTS && validMode(modes[saved])) { activate(saved); armIdle(saved,millis()); }
  else if(saved==PHOTO_SCREEN && showPhotoScreen(currentPhoto,false,false)) {}
  else if(saved==FIRE_SCREEN) enterFire();
  else drawClockFace();
}
void loop() {
  for(int budget=0;budget<192 && Serial.available();budget++) {
    char c=Serial.read();
    if(c=='\n') {
      if(overflow) Serial.println("ERR LENGTH");
      else if(lineLength) {lineBuffer[lineLength]=0;command(lineBuffer);}
      lineLength=0;overflow=false;
    } else if(c!='\r') {
      if(lineLength<(int)sizeof(lineBuffer)-1) lineBuffer[lineLength++]=c;else overflow=true;
    }
  }
  uint32_t now=millis();
  updateCountdown(now);
  updateIdle(now);
  updateNotice(now);
  if(active>=0) drawFace();
  else if(active==PHOTO_SCREEN) updatePhotoScreen(now);
  else if(active==FIRE_SCREEN) updateFire(now);
  else {
    flushCountdown(OWNER_RING);   // no owner ring on the clock, so the timer uses that space
    if(now-lastClockUpdate>=100) {lastClockUpdate=now;drawClock();}
  }
}

void drawClockFace() {

  // Outer circle
  tft.drawCircle(
    CX,
    CY,
    110,
    GC9A01A_WHITE
  );


  // Tick marks
  for (int i = 0; i < 60; i++) {

    float angle =
      i * 2.0 * PI / 60.0
      - PI / 2.0;


    int innerRadius;

    if (i % 5 == 0) {
      innerRadius = 94;
    }
    else {
      innerRadius = 102;
    }


    int x1 =
      CX + cos(angle) * innerRadius;

    int y1 =
      CY + sin(angle) * innerRadius;


    int x2 =
      CX + cos(angle) * 108;

    int y2 =
      CY + sin(angle) * 108;


    tft.drawLine(
      x1,
      y1,
      x2,
      y2,
      GC9A01A_WHITE
    );
  }
}


// ==============================
// Restore clock background
// ==============================

void restoreClockBackground() {

  // Erase old hands
  tft.drawLine(
    CX, CY,
    oldHX, oldHY,
    GC9A01A_BLACK
  );

  tft.drawLine(
    CX, CY,
    oldMX, oldMY,
    GC9A01A_BLACK
  );

  tft.drawLine(
    CX, CY,
    oldSX, oldSY,
    GC9A01A_BLACK
  );


  // Restore tick marks in case a hand crossed them
  drawClockFace();
}


// ==============================
// Draw clock
// ==============================

void drawClock() {

  unsigned long elapsedMS =
    millis() - clockStartMillis;


  unsigned long startSeconds =
      (unsigned long)clockHour * 3600UL
    + (unsigned long)clockMinute * 60UL
    + (unsigned long)clockSecond;


  unsigned long totalSeconds =
    (
      startSeconds +
      elapsedMS / 1000UL
    ) % 86400UL;


  int h =
    totalSeconds / 3600UL;

  int m =
    (totalSeconds % 3600UL) / 60UL;

  int s =
    totalSeconds % 60UL;


  // Fractional seconds for smooth second hand
  float fraction =
    (elapsedMS % 1000UL) / 1000.0;


  restoreClockBackground();


  // ==========================
  // Hour hand
  // ==========================

  float hourAngle =
    (
      (h % 12)
      + m / 60.0
      + s / 3600.0
    )
    * 2.0 * PI / 12.0
    - PI / 2.0;


  int hx =
    CX + cos(hourAngle) * 50;

  int hy =
    CY + sin(hourAngle) * 50;


  // ==========================
  // Minute hand
  // ==========================

  float minuteAngle =
    (
      m
      + s / 60.0
    )
    * 2.0 * PI / 60.0
    - PI / 2.0;


  int mx =
    CX + cos(minuteAngle) * 72;

  int my =
    CY + sin(minuteAngle) * 72;


  // ==========================
  // Second hand
  // ==========================

  float secondAngle =
    (
      s + fraction
    )
    * 2.0 * PI / 60.0
    - PI / 2.0;


  int sx =
    CX + cos(secondAngle) * 90;

  int sy =
    CY + sin(secondAngle) * 90;


  // ==========================
  // Draw hands
  // ==========================

  tft.drawLine(
    CX, CY,
    hx, hy,
    GC9A01A_WHITE
  );


  tft.drawLine(
    CX, CY,
    mx, my,
    GC9A01A_WHITE
  );


  tft.drawLine(
    CX, CY,
    sx, sy,
    GC9A01A_RED
  );


  tft.fillCircle(
    CX,
    CY,
    4,
    GC9A01A_RED
  );


  // Save positions
  oldHX = hx;
  oldHY = hy;

  oldMX = mx;
  oldMY = my;

  oldSX = sx;
  oldSY = sy;
}


