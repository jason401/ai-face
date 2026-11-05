// Deterministic contact-sheet inputs from the actual firmware renderer, no hardware.
#include "fw.cpp"
uint32_t fakeMillis=0; FakeSerial Serial; FakeSPI SPI; FakeFS LittleFS; FakeWire Wire;
int main(){static uint16_t fb[240*240];tft.fb=fb;setup();
  const char *names[]={"original","clear-night","clear-day","partly-cloudy","overcast","rain","snow","fog"};
  int kinds[]={0,0,0,1,2,3,4,5}, clouds[]={0,0,0,45,100,95,90,100};
  for(int mode=0;mode<8;mode++){
    weatherActive=false;fireRng=0x9E3779B9u;weatherRng=0xA341316Cu;weatherFrame=0;fireInit();
    setFireWeather(mode!=0,kinds[mode],mode==2?100:0,clouds[mode],65,mode>=3?35:0);
    tft.fillScreen(0);for(int f=0;f<100;f++)fireStep();drawFire();
    std::string path=std::string(names[mode])+".ppm";FILE *out=fopen(path.c_str(),"wb");
    fprintf(out,"P6\n240 240\n255\n");
    for(auto c:fb){unsigned char px[3]={(unsigned char)(((c>>11)&31)*255/31),(unsigned char)(((c>>5)&63)*255/63),(unsigned char)((c&31)*255/31)};fwrite(px,1,3,out);}fclose(out);
  }
}
