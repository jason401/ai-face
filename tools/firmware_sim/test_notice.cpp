#include "fw.cpp"
uint32_t fakeMillis=0; FakeSerial Serial; FakeSPI SPI; FakeFS LittleFS;
std::string cmd(const std::string&c){Serial.out.clear();Serial.in=c+"\n";while(Serial.available())loop();std::string r=Serial.out;while(!r.empty()&&(r.back()=='\n'||r.back()=='\r'))r.pop_back();return r;}
void run(uint32_t ms){for(uint32_t t=0;t<ms;t+=20){fakeMillis+=20;loop();}}
int fails=0;
#define CHECK(c) do{if(!(c)){printf("FAIL line %d: %s\n",__LINE__,#c);fails++;}}while(0)
int main(){ static uint16_t fb[240*240]; tft.fb=fb; setup();
  for(int s:{0,3,8}){ cmd("BEGIN:"+std::to_string(s)+":1"); cmd("FRAME:400,800,100,100,0,0,70,5,0,0,0,0,0,0,0,0"); cmd("COMMIT"); }
  CHECK(cmd("SAVER:30:0:0:60")=="OK SAVER"); CHECK(cmd("PLAY:0")=="OK PLAY");
  run(19000); CHECK(noticeSeg==-1 && noticeDrawn==-1);
  run(1500); CHECK(noticeSeg>=0 && noticeSeg<30 && noticeDrawn==noticeSeg);
  run(5000); CHECK(noticeSeg>80 && noticeSeg<110);
  // grab a frame mid-way for a look
  FILE*o=fopen("notice.raw","wb"); fwrite(fb,2,240*240,o); fclose(o);
  CHECK(cmd("PLAY:0")=="OK PLAY"); run(100); CHECK(noticeSeg==-1 && noticeDrawn==-1);   // new face: gone
  run(25000); CHECK(noticeSeg>0); CHECK(cmd("TIMER:60:60:2")=="OK TIMER"); run(100); CHECK(noticeSeg==-1);   // timer has priority
  CHECK(cmd("TIMER:0:0:2")=="OK TIMER"); run(6000); CHECK(active==3 && noticeSeg==-1);          // saver started on time
  CHECK(cmd("SAVER:30:4:0:60")=="OK SAVER"); CHECK(cmd("PLAY:0")=="OK PLAY"); run(25000); CHECK(noticeSeg==-1);   // off: no notice
  printf(fails?"%d FAILED\n":"NOTICE OK\n",fails); return fails;}
