#include "fw.cpp"
uint32_t fakeMillis=0; FakeSerial Serial; FakeSPI SPI; FakeFS LittleFS; FakeWire Wire;
int failures=0;
#define CHECK(c) do {if(!(c)){printf("FAIL %d: %s\n",__LINE__,#c);failures++;}}while(0)
std::string cmd(const std::string &s){Serial.out.clear();Serial.in=s+"\n";while(Serial.available())loop();std::string r=Serial.out;while(!r.empty()&&(r.back()=='\n'||r.back()=='\r'))r.pop_back();return r;}
int main(){setup();fireInit();
  CHECK(cmd("WEATHER:1:3:0:90:70:-80")=="OK WEATHER");
  CHECK(weatherActive&&weatherKind==3&&weatherTarget[3]==-80);
  CHECK(cmd("WEATHER:1:6:0:90:70:0")=="ERR COMMAND");
  CHECK(cmd("WEATHER:1:3:0:101:70:0")=="ERR COMMAND");
  CHECK(cmd("WEATHER:1:3:0:90:70:101")=="ERR COMMAND");
  CHECK(cmd("WEATHER:1:3:0:90:70:0:extra")=="ERR COMMAND");
  for(int kind=0;kind<6;kind++){
    setFireWeather(1,kind,0,kind==0?0:100,80,100);
    for(int f=0;f<500;f++){
      fireStep();
      for(auto &d:weatherDrops){CHECK(d.x>=0&&d.x<FG);CHECK(d.y>=0&&d.y<FG);}
      CHECK(weatherDay>=0&&weatherDay<=100);CHECK(weatherCloud>=0&&weatherCloud<=100);
      for(int y=0;y<FG;y++)for(int x=0;x<FG;x++)fireCell(x,y,200);
    }
    int rain=0;for(auto v:weatherRain)rain+=v!=0;
    CHECK((kind==3||kind==4)?rain>0:rain==0);
  }
  memset(fireHeat,0,sizeof(fireHeat));
  stars[0].x=26;stars[0].y=5;stars[0].age=stars[0].life/2;
  setFireWeather(0,0,0,0,0,0);
  uint16_t original=fireCell(26,5,200);
  CHECK(original==fireBaseCell(26,5,200)); // weather disabled is the original renderer
  setFireWeather(1,0,100,0,0,0);
  CHECK(fireCell(26,5,200)==fireWeatherSky(26,5,fireBack[5*FG+26])); // no stars in daylight
  CHECK(fireCell(26,5,200)!=original);
  setFireWeather(1,2,0,100,0,0);weatherCloud=100;
  CHECK(fireCell(26,5,200)==fireWeatherSky(26,5,fireBack[5*FG+26])); // no stars in full overcast
  CHECK(cmd("WEATHER:0:0:0:0:0:0")=="OK WEATHER");CHECK(!weatherActive);
  setFireWeather(1,3,0,100,60,20);
  fakeMillis+=7200001u;stepFireWeather();CHECK(!weatherActive); // no stale weather if the Mac sleeps/disconnects
  printf(failures?"%d WEATHER FAILURES\n":"WEATHER OK\n",failures);return failures;
}
