#include "fw.cpp"
uint32_t fakeMillis=0; FakeSerial Serial; FakeSPI SPI; FakeFS LittleFS;
std::string cmd(const std::string&c){Serial.out.clear();Serial.in=c+"\n";while(Serial.available())loop();std::string r=Serial.out;while(!r.empty()&&(r.back()=='\n'||r.back()=='\r'))r.pop_back();return r;}
void run(uint32_t ms){for(uint32_t t=0;t<ms;t+=20){fakeMillis+=20;loop();}}
int fails=0;
#define CHECK(c) do{if(!(c)){printf("FAIL line %d: %s\n",__LINE__,#c);fails++;}}while(0)
uint16_t at(uint16_t*fb,int x,int y){return fb[y*240+x];}
bool gray(uint16_t c){int r=(c>>11)<<3,g=((c>>5)&63)<<2,b=(c&31)<<3; return abs(r-g)<=8 && abs(g-b)<=8;}
int main(){ static uint16_t fb[240*240]; tft.fb=fb; setup();
  CHECK(cmd("HELLO")=="OK FACE8");
  // the new effect bits (wave, bulb, pray, salute, palm) are valid frame data; beyond them is not
  CHECK(cmd("BEGIN:0:1")=="OK BEGIN");
  CHECK(cmd("FRAME:400,800,100,100,0,0,70,18,0,0,0,0,0,7168,0,0")=="OK FRAME");
  CHECK(cmd("COMMIT")=="OK COMMIT");
  CHECK(cmd("BEGIN:1:1")=="OK BEGIN");
  CHECK(cmd("FRAME:400,800,100,100,0,0,70,18,0,0,0,0,0,24576,0,0")=="OK FRAME");
  CHECK(cmd("COMMIT")=="OK COMMIT");
  CHECK(cmd("BEGIN:2:1")=="OK BEGIN");
  CHECK(cmd("FRAME:400,800,100,100,0,0,70,18,0,0,0,0,0,32768,0,0")=="ERR FRAME");
  CHECK(cmd("OWNER:1")=="OK OWNER"); CHECK(cmd("PLAY:0")=="OK PLAY"); run(1500);
  FILE*o=fopen("style_color.raw","wb"); fwrite(fb,2,240*240,o); fclose(o);
  uint16_t glass=at(fb,190,60); CHECK(glass!=0 && !gray(glass));          // yellow bulb
  CHECK(at(fb,110,190)!=0);                                               // praying hands
  CHECK(cmd("PLAY:1")=="OK PLAY"); run(1500);
  CHECK(at(fb,185,67)!=0);                                                // salute fingers
  CHECK(at(fb,84,80)!=0 && at(fb,45,140)!=0);                            // facepalm palm + forearm
  CHECK(cmd("PLAY:0")=="OK PLAY"); run(1500);
  // owner ring: Claude orange in color
  CHECK(ringColor(1)!=0xFFFF);
  // monochrome: grays only, patterned ring, kept across restarts
  CHECK(cmd("STYLE:1")=="OK STYLE"); CHECK(cmd("STYLE:2")=="ERR COMMAND"); run(500);
  glass=at(fb,190,60); CHECK(glass!=0 && gray(glass));
  int on=0; for(int i=0;i<180;i++) on+=ringColor(i*2+1.0f)==0xFFFF;
  CHECK(on>100 && on<125);                                                // Claude: dashes
  CHECK(cmd("OWNER:2")=="OK OWNER"); run(2000);
  on=0; for(int i=0;i<180;i++) on+=ringColor(i*2+1.0f)==0xFFFF; CHECK(on==150);   // GPT: six arcs
  CHECK(cmd("OWNER:0")=="OK OWNER"); run(2000);
  on=0; for(int i=0;i<180;i++) on+=ringColor(i*2+1.0f)==0xFFFF; CHECK(on==180);   // app: solid
  CHECK(cmd("TIMER:60:60:4")=="OK TIMER"); run(100); CHECK(cdColor(359)==0xFFFF);   // timer white, not red
  o=fopen("style_mono.raw","wb"); fwrite(fb,2,240*240,o); fclose(o);
  CHECK(prefs.getBool("mono",false));
  mono=false; setup(); CHECK(mono);
  CHECK(cmd("STYLE:0")=="OK STYLE"); CHECK(!mono && !prefs.getBool("mono",true));
  printf(fails?"%d FAILED\n":"STYLE OK\n",fails); return fails;}
