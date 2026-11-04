#include "fw.cpp"
uint32_t fakeMillis=0; FakeSerial Serial; FakeSPI SPI; FakeFS LittleFS; FakeWire Wire;
std::string cmd(const std::string&c){Serial.out.clear();Serial.in=c+"\n";while(Serial.available())loop();std::string r=Serial.out;while(!r.empty()&&(r.back()=='\n'||r.back()=='\r'))r.pop_back();return r;}
void run(uint32_t ms){for(uint32_t t=0;t<ms;t+=20){fakeMillis+=20;loop();}}
int fails=0;
#define CHECK(c) do{if(!(c)){printf("FAIL line %d: %s\n",__LINE__,#c);fails++;}}while(0)
int main(){
  setup();
  CHECK(cmd("CLOCKSTYLE:10")=="ERR COMMAND"); CHECK(cmd("CLOCKSTYLE:-1")=="ERR COMMAND"); CHECK(cmd("DATE:0")=="ERR COMMAND");
  CHECK(cmd("TIME:10:09:37")=="OK TIME"); CHECK(cmd("DATE:20761")=="OK DATE");   // Wed 4 Nov 2026
  CHECK(cmd("CLOCKSTYLE:7")=="OK CLOCKSTYLE"); CHECK(prefs.getInt("clockstyle",0)==7);
  CHECK(cmd("CLOCK")=="OK CLOCK"); run(300);
  CHECK(lastClockStyle==7 && lastClockTime.h==10 && lastClockTime.m==9);
  CHECK(lastClockTime.date && lastClockTime.day==4 && lastClockTime.month==11 && lastClockTime.wday==3);
  // Midnight: the date rolls over by itself
  CHECK(cmd("TIME:23:59:59")=="OK TIME"); CHECK(cmd("DATE:20761")=="OK DATE"); run(1500);
  CHECK(lastClockTime.h==0 && lastClockTime.day==5 && lastClockTime.wday==4);
  // The design is remembered after a restart; changing it redraws a clock on screen at once
  setup(); CHECK(clockStyle==7);
  CHECK(cmd("CLOCKSTYLE:2")=="OK CLOCKSTYLE"); CHECK(lastClockStyle==2);
  printf(fails?"clock: %d FAILED\n":"clock: OK\n",fails);
  return fails?1:0;
}
