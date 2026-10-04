#include "fw.cpp"
uint32_t fakeMillis=0; FakeSerial Serial; FakeSPI SPI; FakeFS LittleFS;
int main(){ static uint16_t fb[240*240]; tft.fb=fb; setup();
  Serial.in="FIRE\n"; while(Serial.available()) loop();
  FILE*o=fopen("fire.raw","wb");
  for(int f=0;f<40;f++){ for(int t=0;t<4;t++){fakeMillis+=20;loop();} fwrite(fb,2,240*240,o);} fclose(o);
  printf("%s active=%d\n",Serial.out.c_str(),active);}
