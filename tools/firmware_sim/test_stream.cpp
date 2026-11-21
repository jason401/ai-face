#include "fw.cpp"
uint32_t fakeMillis=0; FakeSerial Serial; FakeSPI SPI; FakeFS LittleFS; FakeWire Wire;
std::string strip(std::string r){while(!r.empty()&&(r.back()=='\n'||r.back()=='\r'))r.pop_back();return r;}
std::string send(const std::string&c){Serial.out.clear();Serial.in=c;while(Serial.available())loop();return strip(Serial.out);}
std::string cmd(const std::string&c){return send(c+"\n");}
void run(uint32_t ms){for(uint32_t t=0;t<ms;t+=20){fakeMillis+=20;loop();}}
int fails=0;
#define CHECK(c) do{if(!(c)){printf("FAIL line %d: %s\n",__LINE__,#c);fails++;}}while(0)
void upload(int slot){
  CHECK(cmd("BEGIN:"+std::to_string(slot)+":1")=="OK BEGIN");
  CHECK(cmd("FRAME:400,800,100,100,0,0,70,0,0,0,0,0,0,0,0,0")=="OK FRAME");
  CHECK(cmd("COMMIT")=="OK COMMIT");
}
std::string header(int x,int y,int w,int h,int enc,const std::string&data){
  return "STREAM:"+std::to_string(x)+":"+std::to_string(y)+":"+std::to_string(w)+":"+std::to_string(h)+":"
    +std::to_string(enc)+":"+std::to_string(data.size())+":"+std::to_string(adler32((const uint8_t*)data.data(),data.size()))+"\n";
}
std::string raw(int n,uint16_t c){std::string s; for(int i=0;i<n;i++){s+=(char)(c&255); s+=(char)(c>>8);} return s;}
std::string runs(std::vector<std::pair<int,uint16_t>> r){std::string s; for(auto&p:r){s+=(char)(p.first-1); s+=(char)(p.second&255); s+=(char)(p.second>>8);} return s;}
int main(){
  static uint16_t screen[240*240]; tft.fb=screen;
  setup();
  upload(0); CHECK(cmd("PLAY:0")=="OK PLAY"); CHECK(active==0 && idleArmed);
  CHECK(cmd("SAVER:60:0:0:60")=="OK SAVER");
  // Not streaming yet: a picture is read (not taken as commands) and refused.
  CHECK(send(header(0,0,2,1,0,raw(2,0x1234))+raw(2,0x1234))=="ERR COMMAND");
  CHECK(cmd("STREAM:PING")=="ERR STREAM");
  CHECK(cmd("STREAM:ON")=="OK STREAM"); CHECK(active==STREAM_SCREEN && !idleArmed && screen[0]==0);
  // Raw rectangle, bytes include newlines on purpose.
  { std::string d=raw(10*3,0x0A0A); CHECK(send(header(5,7,10,3,0,d)+d)=="OK STREAM");
    CHECK(screen[7*240+5]==0x0A0A && screen[9*240+14]==0x0A0A && screen[10*240+5]==0 && screen[7*240+15]==0); }
  // Runs: 4 red then 4 blue in a 4x2 rectangle.
  { std::string d=runs({{4,0xF800},{4,0x001F}}); CHECK(send(header(100,100,4,2,1,d)+d)=="OK STREAM");
    CHECK(screen[100*240+103]==0xF800 && screen[101*240+100]==0x001F); }
  // A long run (256 pixels in one entry).
  { std::string d=runs({{256,0x07E0},{224,0x07E0}}); CHECK(send(header(0,200,240,2,1,d)+d)=="OK STREAM");
    CHECK(screen[201*240+239]==0x07E0); }
  // Broken: wrong checksum, too few runs, outside the screen, too big. Old picture stays; next one works.
  { std::string d=raw(4,0xFFFF); std::string h=header(0,0,2,2,0,d); h.replace(h.rfind(':')+1,std::string::npos,"1\n");
    CHECK(send(h+d)=="ERR DATA"); CHECK(screen[0]==0); }
  { std::string d=runs({{3,0xFFFF}}); CHECK(send(header(0,0,2,2,1,d)+d)=="ERR DATA"); }
  { std::string d=raw(4,0xFFFF); CHECK(send(header(239,0,2,2,0,d)+d)=="ERR COMMAND"); }
  CHECK(cmd("STREAM:0:0:240:33:0:15840:1")=="ERR COMMAND");
  CHECK(cmd("STREAM:PING")=="OK STREAM"); CHECK(active==STREAM_SCREEN);
  // Keeps going while the Mac talks; a swipe-free saver does not interrupt it.
  for(int i=0;i<40;i++){ run(1000); CHECK(cmd("STREAM:PING")=="OK STREAM"); }
  CHECK(active==STREAM_SCREEN);
  // STREAM:OFF: back to the face, saver armed again.
  CHECK(cmd("STREAM:OFF")=="OK STREAM"); CHECK(active==0 && idleArmed);
  CHECK(cmd("STREAM:OFF")=="OK STREAM"); CHECK(active==0);
  // The Mac goes quiet: back by itself after 3 s, and it says so.
  CHECK(cmd("FIRE")=="OK FIRE"); CHECK(cmd("STREAM:ON")=="OK STREAM");
  Serial.out.clear(); run(2900); CHECK(active==STREAM_SCREEN);
  run(200); CHECK(active==FIRE_SCREEN); CHECK(strip(Serial.out)=="EVT SCREEN:fire");
  { std::string d=raw(1,1); CHECK(send(header(0,0,1,1,0,d)+d)=="ERR STREAM"); }
  // Another screen chosen meanwhile replaces the stream screen.
  CHECK(cmd("STREAM:ON")=="OK STREAM"); CHECK(cmd("PLAY:0")=="OK PLAY"); CHECK(active==0);
  CHECK(cmd("STREAM:PING")=="ERR STREAM");
  // A swipe leaves the stream screen (no slide).
  Wire.id=0xB4; setup(); upload(0); CHECK(cmd("PLAY:0")=="OK PLAY"); CHECK(cmd("STREAM:ON")=="OK STREAM");
  Serial.out.clear(); Wire.down=true; for(int i=0;i<=10;i++){Wire.x=200-16*i; Wire.y=120; run(20);} Wire.down=false; run(100);
  CHECK(active==FIRE_SCREEN && !sliding); CHECK(strip(Serial.out)=="EVT SCREEN:fire");
  printf(fails?"%d FAILED\n":"ALL OK\n",fails); return fails!=0;
}
