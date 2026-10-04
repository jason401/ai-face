#include "fw.cpp"
uint32_t fakeMillis=0; FakeSerial Serial; FakeSPI SPI; FakeFS LittleFS;
std::string cmd(const std::string&c){Serial.out.clear();Serial.in=c+"\n";while(Serial.available())loop();std::string r=Serial.out;while(!r.empty()&&(r.back()=='\n'||r.back()=='\r'))r.pop_back();return r;}
void run(uint32_t ms){for(uint32_t t=0;t<ms;t+=20){fakeMillis+=20;loop();}}
int fails=0;
#define CHECK(c) do{if(!(c)){printf("FAIL line %d: %s\n",__LINE__,#c);fails++;}}while(0)
void upload(int slot,int frames){
  CHECK(cmd("BEGIN:"+std::to_string(slot)+":"+std::to_string(frames))=="OK BEGIN");
  for(int i=0;i<frames;i++) CHECK(cmd("FRAME:400,800,100,100,0,0,70,"+std::to_string(i+slot)+",0,0,0,0,0,0,0,0")=="OK FRAME");
  CHECK(cmd("COMMIT")=="OK COMMIT");
}
std::string makeImg(int seed,uint32_t &sum){std::string img;sum=0;for(int i=0;i<115200;i++){uint8_t b=(i*7+seed*13+(i>>9))&0xFF;if(i%5==0)b='\n';img+=(char)b;sum=sum*31u+b;}return img;}
std::string sendPhoto(int id,int seed){
  uint32_t s; std::string img=makeImg(seed,s);
  std::string r=cmd("PHOTO:BEGIN:"+std::to_string(id)+":115200"); if(r!="OK PHOTO") return r;
  for(size_t o=0;o<img.size();o+=4096){size_t n=min<size_t>(4096,img.size()-o);Serial.out.clear();Serial.in="PHOTO:DATA:"+std::to_string(n)+"\n"+img.substr(o,n);while(Serial.available())loop();if(Serial.out!="OK DATA\r\n")return Serial.out;}
  return cmd("PHOTO:END:"+std::to_string(s));
}
int main(){
  // FACE6 leftover photo gets migrated to photo 0
  uint32_t s0; LittleFS.files["/photo.raw"]=makeImg(99,s0); prefs.putBytes("idle",&s0,4);
  setup();
  CHECK(LittleFS.files.count("/p0.raw") && !LittleFS.files.count("/photo.raw") && currentPhoto==0 && !prefs.isKey("idle"));
  CHECK(cmd("HELLO")=="OK FACE7");
  CHECK(cmd("PHOTO:LIST")=="OK LIST:1:0");
  for(int s:{0,3,8}) upload(s,3);
  CHECK(cmd("SAVER:60:0:0:60")=="OK SAVER");
  CHECK(cmd("SAVER:60:6:0:60")=="ERR COMMAND"); CHECK(cmd("SAVER:60:2:0:2")=="ERR COMMAND");
  long w=prefs.writes; CHECK(cmd("SAVER:60:0:0:60")=="OK SAVER"); CHECK(prefs.writes==w);
  // sleep saver
  CHECK(cmd("PLAY:0")=="OK PLAY"); run(59000); CHECK(active==0); run(2000); CHECK(active==3); run(60000); CHECK(active==8);
  run(600000); CHECK(active==8);
  CHECK(cmd("PLAY:0")=="OK PLAY"); CHECK(active==0);
  // clock saver: not synced -> falls back to sleepy
  CHECK(cmd("SAVER:60:1:0:60")=="OK SAVER"); run(61000); CHECK(active==3);
  CHECK(cmd("TIME:10:00:00")=="OK TIME"); CHECK(cmd("PLAY:0")=="OK PLAY"); run(61000); CHECK(active==CLOCK_SCREEN);
  // timer alarm wakes
  CHECK(cmd("TIMER:2:2:4")=="OK TIMER"); run(2500); CHECK(active==0);
  // photo saver with clock overlay
  CHECK(cmd("SAVER:60:2:1:60")=="OK SAVER"); CHECK(cmd("PLAY:0")=="OK PLAY"); run(61000);
  CHECK(active==PHOTO_SCREEN && shownPhoto==0 && photoOverlay && !slideshow);
  long px=tft.pixels; run(60000); CHECK(tft.pixels>px);   // redrawn when the minute changes
  CHECK(cmd("PLAY:1")=="ERR COMMAND"); CHECK(cmd("PLAY:0")=="OK PLAY"); CHECK(active==0);
  // more photos, slideshow
  { std::string r=sendPhoto(4,1); if(r!="OK PHOTO") printf("send4: [%s]\n",r.c_str()); } CHECK(active==PHOTO_SCREEN && shownPhoto==4 && currentPhoto==4 && !idleArmed && !photoOverlay);
  CHECK(sendPhoto(7,2)=="OK PHOTO"); CHECK(cmd("PHOTO:LIST")=="OK LIST:145:7");
  CHECK(cmd("SAVER:30:3:0:10")=="OK SAVER"); CHECK(cmd("PLAY:0")=="OK PLAY"); run(31000);
  CHECK(active==PHOTO_SCREEN && slideshow && shownPhoto==7);
  run(10500); CHECK(shownPhoto==0); run(10000); CHECK(shownPhoto==4); run(10000); CHECK(shownPhoto==7);
  // delete the photo on screen -> next one
  CHECK(cmd("PHOTO:DEL:7")=="OK PHOTO"); CHECK(shownPhoto==0 && currentPhoto==0 && cmd("PHOTO:LIST")=="OK LIST:17:0");
  // chosen photo + reboot
  CHECK(cmd("PHOTO:SHOW:4")=="OK PHOTO"); CHECK(currentPhoto==4 && savedActive==PHOTO_SCREEN);
  CHECK(cmd("PHOTO:SHOW:7")=="ERR NOPHOTO");
  setup(); CHECK(active==PHOTO_SCREEN && shownPhoto==4 && !photoOverlay);
  CHECK(cmd("PHOTO:DEL:4")=="OK PHOTO"); CHECK(cmd("PHOTO:DEL:0")=="OK PHOTO"); CHECK(active==CLOCK_SCREEN && savedActive==CLOCK_SCREEN && currentPhoto==-1);
  CHECK(cmd("PHOTO:SHOW")=="ERR NOPHOTO");
  // photo saver without photos -> sleepy
  CHECK(cmd("SAVER:30:2:1:10")=="OK SAVER"); CHECK(cmd("PLAY:0")=="OK PLAY"); run(31000); CHECK(active==3);
  // off
  CHECK(cmd("SAVER:30:4:0:10")=="OK SAVER"); CHECK(cmd("PLAY:0")=="OK PLAY"); run(600000); CHECK(active==0);
  // storage full
  int ok=0; for(int i=0;i<10;i++) if(sendPhoto(i,i)=="OK PHOTO") ok++;
  printf("photos stored before full: %d\n",ok); CHECK(ok>=9);
  LittleFS.total=300000; CHECK(sendPhoto(9,3)=="ERR FULL"); LittleFS.total=1500000;
  // corrupted transfer keeps old
  CHECK(cmd("PHOTO:BEGIN:2:115200")=="OK PHOTO"); CHECK(cmd("PHOTO:END:5")=="ERR DATA");
  // overlay pixels: hands white over photo
  { uint16_t strip[240*8]; for(auto&p:strip)p=0x1234; Hand hd[3]={{120,120,120,65,3},{120,120,205,120,2},{120,120,120,120,5}};
    overlayStrip(strip,116,8,hd,2); CHECK(strip[(120-116)*240+150]==0xFFFF); CHECK(strip[(117-116)*240+150]==shade(0x1234)); CHECK(strip[0]==0x1234); }
  printf(fails?"%d FAILED\n":"ALL OK\n",fails); return fails!=0;
}
