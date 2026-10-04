// Renders one face per mood with the real firmware drawing code (see tools/make_preview.py).
// stdin: per mood one FRAME line (16 numbers); stdout file: 200x180 RGB565 canvases in order.
#include "fw.cpp"
uint32_t fakeMillis=0; FakeSerial Serial; FakeSPI SPI; FakeFS LittleFS;
std::string cmd(const std::string&c){Serial.out.clear();Serial.in=c+"\n";while(Serial.available())loop();return Serial.out;}
void run(uint32_t ms){for(uint32_t t=0;t<ms;t+=20){fakeMillis+=20;loop();}}
int main(int argc,char**argv){
  setup();
  FILE*out=fopen(argv[1],"wb");
  char line[256]; int slot=0;
  while(fgets(line,sizeof line,stdin)){
    std::string f(line); while(!f.empty()&&(f.back()=='\n'||f.back()=='\r')) f.pop_back();
    if(f.empty()) continue;
    slot=1-slot;   // alternate slots so every mood starts fresh from the previous pose
    cmd("BEGIN:"+std::to_string(slot)+":1"); 
    if(cmd("FRAME:"+f)!="OK FRAME\r\n"){ fprintf(stderr,"bad frame %s\n",f.c_str()); return 1; }
    cmd("COMMIT"); cmd("PLAY:"+std::to_string(slot));
    run(1200);
    fwrite(canvas.getBuffer(),2,CW*CH,out);
  }
  fclose(out); return 0;
}
