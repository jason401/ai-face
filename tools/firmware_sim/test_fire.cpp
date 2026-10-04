#include "fw.cpp"
uint32_t fakeMillis=0; FakeSerial Serial; FakeSPI SPI; FakeFS LittleFS;
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
  printf(fails?"%d FAILED\n":"FIRE OK\n",fails); return fails;}
