#include "fw.cpp"
uint32_t fakeMillis=0; FakeSerial Serial; FakeSPI SPI; FakeFS LittleFS; FakeWire Wire;
std::string cmd(const std::string&c){Serial.out.clear();Serial.in=c+"\n";while(Serial.available())loop();std::string r=Serial.out;while(!r.empty()&&(r.back()=='\n'||r.back()=='\r'))r.pop_back();return r;}
void run(uint32_t ms){for(uint32_t t=0;t<ms;t+=20){fakeMillis+=20;loop();}}
int fails=0;
#define CHECK(c) do{if(!(c)){printf("FAIL line %d: %s\n",__LINE__,#c);fails++;}}while(0)
void upload(int slot){
  CHECK(cmd("BEGIN:"+std::to_string(slot)+":1")=="OK BEGIN");
  CHECK(cmd("FRAME:400,800,100,100,0,0,70,0,0,0,0,0,0,0,0,0")=="OK FRAME");
  CHECK(cmd("COMMIT")=="OK COMMIT");
}
// A finger moving from (x0,y) to (x1,y) over ~200 ms, then lifted; returns what the board said.
std::string drag(int x0,int x1,int y0=120,int y1=120){
  Serial.out.clear();
  Wire.down=true; for(int i=0;i<=10;i++){Wire.x=x0+(x1-x0)*i/10; Wire.y=y0+(y1-y0)*i/10; run(20);}
  Wire.down=false; run(400);   // the slide finishes (or springs back)
  std::string r=Serial.out; while(!r.empty()&&(r.back()=='\n'||r.back()=='\r'))r.pop_back(); return r;
}
int main(){
  // No touch chip: setup and everything else work as before.
  setup();
  CHECK(cmd("TOUCH")=="OK TOUCH:0");
  CHECK(drag(200,40)=="");

  Wire.id=0xB4; setup();
  CHECK(cmd("TOUCH")=="OK TOUCH:180");
  upload(0); CHECK(cmd("PLAY:0")=="OK PLAY"); CHECK(active==0);
  // Clock not set yet: face -> fire -> (clock skipped) -> face
  CHECK(drag(200,40)=="EVT SCREEN:fire"); CHECK(active==FIRE_SCREEN);
  CHECK(drag(200,40)=="EVT SCREEN:face"); CHECK(active==0);
  CHECK(cmd("TIME:10:00:00")=="OK TIME");
  // Swipe left: face -> fire -> clock -> face; right goes back
  CHECK(drag(200,40)=="EVT SCREEN:fire");
  CHECK(drag(200,40)=="EVT SCREEN:clock"); CHECK(active==CLOCK_SCREEN);
  CHECK(drag(200,40)=="EVT SCREEN:face"); CHECK(active==0);
  CHECK(drag(40,200)=="EVT SCREEN:clock");
  CHECK(drag(40,200)=="EVT SCREEN:fire");
  CHECK(drag(40,200)=="EVT SCREEN:face");
  // Taps, short moves and vertical drags change nothing
  CHECK(drag(120,125)==""); CHECK(drag(120,150)==""); CHECK(drag(120,140,40,200)==""); CHECK(active==0);
  // The screens move with the finger, and a short slow drag springs back
  Serial.out.clear(); Wire.down=true; Wire.x=200; Wire.y=120; run(20);
  for(int i=1;i<=8;i++){Wire.x=200-i*5; run(80);}          // 40 px over 640 ms
  CHECK(sliding && lroundf(slideOffset)==-40 && slideTo==1);
  Wire.down=false; run(400);
  CHECK(!sliding && active==0 && Serial.out=="");
  // Far enough (but slow) finishes; the face shown by the slide continues as the face
  CHECK(drag(200,40)=="EVT SCREEN:fire");
  Wire.down=true; Wire.x=40; Wire.y=120; run(20);
  for(int i=1;i<=8;i++){Wire.x=40+i*12; run(80);}         // 96 px slowly to the right
  Wire.down=false; run(400); CHECK(!sliding && active==0);
  // Anything chosen from the Mac during a slide cancels it
  Wire.down=true; Wire.x=200; run(20); Wire.x=170; run(20); CHECK(sliding);
  CHECK(cmd("PLAY:0")=="OK PLAY"); CHECK(!sliding && active==0);
  Wire.down=false; run(400); CHECK(!sliding && active==0);
  // A face reached by swiping restarts the saver countdown
  CHECK(cmd("SAVER:60:0:0:60")=="OK SAVER");
  drag(200,40); drag(40,200); CHECK(active==0 && idleArmed);
  // The fire/clock reached by swiping are kept after a restart, like the app's buttons
  drag(200,40); setup(); CHECK(active==FIRE_SCREEN);
  printf(fails?"touch: %d FAILED\n":"touch: OK\n",fails);
  return fails?1:0;
}
