#include "fw.cpp"
uint32_t fakeMillis=0; FakeSerial Serial; FakeSPI SPI; FakeFS LittleFS; FakeWire Wire;
std::string cmd(const std::string&c){Serial.out.clear();Serial.in=c+"\n";while(Serial.available())loop();std::string r=Serial.out;while(!r.empty()&&(r.back()=='\n'||r.back()=='\r'))r.pop_back();return r;}
void run(uint32_t ms){for(uint32_t t=0;t<ms;t+=20){fakeMillis+=20;loop();}}
int fails=0;
#define CHECK(c) do{if(!(c)){printf("FAIL line %d: %s (duty %d)\n",__LINE__,#c,lastDuty);fails++;}}while(0)
void upload(int slot){
  CHECK(cmd("BEGIN:"+std::to_string(slot)+":1")=="OK BEGIN");
  CHECK(cmd("FRAME:400,800,100,100,0,0,70,0,0,0,0,0,0,0,0,0")=="OK FRAME");
  CHECK(cmd("COMMIT")=="OK COMMIT");
}
void tap(){ Wire.down=true; Wire.x=120; Wire.y=120; run(60); Wire.x=40; run(200); Wire.down=false; run(600); }
int main(){
  Wire.id=0xB6; setup(); run(100);
  CHECK(lastDuty==255);                                        // full brightness by default
  for(auto bad:{"LIGHT:5:0:0:0:7","LIGHT:50:2:0:0:7","LIGHT:50:0:0:24:7","LIGHT:50:0:0:0"}) CHECK(cmd(bad)=="ERR COMMAND");
  CHECK(cmd("LIGHT:50:1:0:0:7")=="OK LIGHT"); run(500); CHECK(lastDuty==128);   // fades to 50 %
  upload(0); upload(8); CHECK(cmd("PLAY:0")=="OK PLAY"); run(500); CHECK(lastDuty==128);
  // Off while the sleeping face shows; a touch lights it for 30 s and does not swipe
  CHECK(cmd("PLAY:8")=="OK PLAY"); run(500); CHECK(lastDuty==0);
  tap(); CHECK(lastDuty==128 && active==8 && !sliding);
  run(29000); CHECK(lastDuty==128); run(1500); CHECK(lastDuty==0);
  CHECK(cmd("PLAY:0")=="OK PLAY"); run(500); CHECK(lastDuty==128);   // a new face: lit again
  // Off at night (also across midnight), lit outside; an alarm lights it
  CHECK(cmd("LIGHT:100:0:1:0:7")=="OK LIGHT"); CHECK(cmd("TIME:01:00:00")=="OK TIME"); run(500); CHECK(lastDuty==0);
  CHECK(cmd("TIME:08:00:00")=="OK TIME"); run(500); CHECK(lastDuty==255);
  CHECK(cmd("LIGHT:100:0:1:22:6")=="OK LIGHT"); CHECK(cmd("TIME:23:30:00")=="OK TIME"); run(500); CHECK(lastDuty==0);
  CHECK(cmd("TIMER:1:1:2")=="OK TIMER"); run(1500); CHECK(lastDuty==255);
  CHECK(cmd("TIMER:0:0:0")=="OK TIMER"); run(500); CHECK(lastDuty==0);
  // Settings survive a restart
  setup(); run(100); CHECK(lightNight && lightFrom==22 && lightTo==6 && lightPct==100);
  printf(fails?"light: %d FAILED\n":"light: OK\n",fails);
  return fails?1:0;
}
