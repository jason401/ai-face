#include "fw.cpp"
uint32_t fakeMillis=0; FakeSerial Serial; FakeSPI SPI; FakeFS LittleFS; FakeWire Wire;
std::string cmd(const std::string&c){Serial.out.clear();Serial.in=c+"\n";while(Serial.available())loop();std::string r=Serial.out;while(!r.empty()&&(r.back()=='\n'||r.back()=='\r'))r.pop_back();return r;}
void run(uint32_t ms){for(uint32_t t=0;t<ms;t+=20){fakeMillis+=20;loop();}}
int fails=0;
#define CHECK(c) do{if(!(c)){printf("FAIL line %d: %s\n",__LINE__,#c);fails++;}}while(0)
int main(){ setup();
  for(int s:{0,3,8}){ cmd("BEGIN:"+std::to_string(s)+":1"); cmd("FRAME:400,800,100,100,0,0,70,5,0,0,0,0,0,0,0,0"); cmd("COMMIT"); }
  CHECK(cmd("SAVER:30:5:0:60")=="OK SAVER"); CHECK(cmd("SAVER:30:6:0:60")=="ERR COMMAND");
  CHECK(cmd("PLAY:0")=="OK PLAY"); run(31000); CHECK(active==FIRE_SCREEN);
  long px=tft.pixels; run(1000); CHECK(tft.pixels-px>500);      // animating (~14 fps x 50 rows)
  CHECK(cmd("TIMER:2:2:4")=="OK TIMER"); run(2500); CHECK(active==0);   // alarm wakes the face
  CHECK(cmd("FIRE")=="OK FIRE"); CHECK(active==FIRE_SCREEN && !idleArmed && savedActive==FIRE_SCREEN);
  setup(); CHECK(active==FIRE_SCREEN);                            // stays after a reboot
  CHECK(cmd("PLAY:0")=="OK PLAY"); CHECK(active==0);
  // Stars: in the sky inside the circle, clear of the flames, fading, and moving to new places
  fireInit(); int moved=0, seen=0; uint8_t first[12][2];
  for(int i=0;i<12;i++){first[i][0]=stars[i].x;first[i][1]=stars[i].y;}
  for(int f=0;f<300;f++){ fireStep();
    for(auto &st:stars){ CHECK(st.y>=1&&st.y<=30&&st.x>=fireSpan[st.y][0]&&st.x<=fireSpan[st.y][1]);
      CHECK(!(st.y>10&&abs(st.x*2-51)<26)); CHECK(starLight(st)>=0&&starLight(st)<=255); seen+=starLight(st)<64; } }
  for(int i=0;i<12;i++) moved+=stars[i].x!=first[i][0]||stars[i].y!=first[i][1];
  CHECK(moved>=8); CHECK(seen>0);
  // The scene fills the screen to the round edge (no black band, no stepped circle of cells);
  // a running timer is drawn into it at r 113-119 and the fire does not paint over it.
  static uint16_t fb[240*240]; tft.fb=fb;
  CHECK(cmd("TIMER:0:0:0")=="OK TIMER"); CHECK(cmd("FIRE")=="OK FIRE"); run(500);
  auto at=[&](int x,int y){return fb[y*240+x];};
  CHECK(at(120,1)!=0 && at(1,120)!=0 && at(238,120)!=0 && at(120,238)!=0);   // top sky, sides, ground
  CHECK(cmd("TIMER:60:60:4")=="OK TIMER"); run(1000);
  uint16_t ring=cdColor(359); CHECK(ring!=0);
  CHECK(at(119,4)==ring && at(4,120)==cdColor(271));               // on the ring, through fire frames
  CHECK(at(120,12)!=ring && at(120,0)!=ring);                     // sky inside and outside it
  tft.fb=nullptr;
  printf(fails?"%d FAILED\n":"FIRE OK\n",fails); return fails;}
