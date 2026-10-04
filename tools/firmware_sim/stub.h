// Host-side stand-ins for Arduino/Adafruit APIs used by ESP32_Display.ino (compile + logic test only).
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <cstdlib>
#include <cstdarg>
#include <string>
#include <map>
#include <vector>
#include <algorithm>
using std::min; using std::max;
#define PI 3.14159265358979f
#define DEG_TO_RAD 0.017453292519943295f
template<class T,class L,class H> T constrain(T x,L lo,H hi){return x<lo?lo:(x>hi?hi:x);}
extern uint32_t fakeMillis;
inline uint32_t millis(){return fakeMillis;}
inline void delay(uint32_t ms){fakeMillis+=ms;}
struct FakeSerial {
  std::string in, out;
  void begin(int){}
  size_t setRxBufferSize(size_t n){return n;}
  int available(){return (int)in.size();}
  char read(){char c=in[0]; in.erase(0,1); return c;}
  void println(const char*s){out+=s; out+="\r\n";}
  size_t readBytes(char*b,size_t n){size_t k=min(n,in.size());memcpy(b,in.data(),k);in.erase(0,k);return k;}
  int printf(const char*f,...){char b[256];va_list a;va_start(a,f);int n=vsnprintf(b,sizeof b,f,a);va_end(a);out+=b;return n;}
};
extern FakeSerial Serial;
struct FakeSPI { void begin(int,int,int,int){} };
extern FakeSPI SPI;
struct Adafruit_GFX {
  long pixels=0, tris=0;
  virtual ~Adafruit_GFX(){}
  void fillTriangle(int,int,int,int,int,int,uint16_t){tris++;}
  void fillRect(int,int,int,int,uint16_t){pixels++;}
  void fillRoundRect(int,int,int,int,int,uint16_t){pixels++;}
  void fillCircle(int,int,int,uint16_t){pixels++;}
  void drawLine(int,int,int,int,uint16_t){pixels++;}
  void drawCircle(int,int,int,uint16_t){pixels++;}
  void fillScreen(uint16_t){pixels++;}
  void setTextSize(int){} void setTextColor(uint16_t){} void setCursor(int,int){} void print(char){}
};
struct GFXcanvas16 : Adafruit_GFX { std::vector<uint16_t> buf; GFXcanvas16(int w,int h):buf(w*h){} uint16_t*getBuffer(){return buf.data();} };
struct Adafruit_GC9A01A : Adafruit_GFX {
  Adafruit_GC9A01A(int,int,int){}
  void begin(){} void setRotation(int){}
  uint16_t *fb=nullptr; void drawRGBBitmap(int x,int y,uint16_t*b,int w,int h){pixels++; if(fb) for(int j=0;j<h;j++) for(int i=0;i<w;i++) fb[(y+j)*240+x+i]=b[j*w+i];}
};
#define GC9A01A_BLACK 0
#define GC9A01A_WHITE 0xFFFF
#define GC9A01A_RED 0xF800
struct Preferences {
  std::map<std::string,std::vector<uint8_t>> kv;
  long writes=0;
  void begin(const char*,bool){}
  size_t putBytes(const char*k,const void*v,size_t n){writes++;kv[k].assign((const uint8_t*)v,(const uint8_t*)v+n);return n;}
  size_t getBytesLength(const char*k){auto i=kv.find(k);return i==kv.end()?0:i->second.size();}
  size_t getBytes(const char*k,void*v,size_t n){auto i=kv.find(k);if(i==kv.end())return 0;memcpy(v,i->second.data(),min(n,i->second.size()));return n;}
  void putInt(const char*k,int v){putBytes(k,&v,4);}
  int getInt(const char*k,int d){int v=d; if(getBytesLength(k)==4) getBytes(k,&v,4); return v;}
  void remove(const char*k){kv.erase(k);}
  bool isKey(const char*k){return kv.count(k)>0;}
};
// ESP32 core 3.x global names (esp32-hal-timer.h etc.) so clashes show up here too.
struct hw_timer_t; hw_timer_t* timerBegin(uint32_t); void timerEnd(hw_timer_t*); void timerStart(hw_timer_t*); void timerStop(hw_timer_t*);
void timerRestart(hw_timer_t*); void timerWrite(hw_timer_t*,uint64_t); uint64_t timerRead(hw_timer_t*); uint32_t timerGetFrequency(hw_timer_t*);
void timerAlarm(hw_timer_t*,uint64_t,bool,uint64_t); void timerAttachInterrupt(hw_timer_t*,void(*)()); void timerDetachInterrupt(hw_timer_t*);

// Minimal in-memory LittleFS.
struct FakeFS; extern FakeFS LittleFS;
struct File {
  std::string path; bool w=false, ok=false; size_t pos=0;
  explicit operator bool() const {return ok;}
  size_t size();
  size_t read(uint8_t*b,size_t n);
  size_t write(const uint8_t*b,size_t n);
  void close(){ok=false;}
};
struct FakeFS {
  std::map<std::string,std::string> files; bool mounted=true;
  bool begin(bool){return mounted;}
  size_t total=1500000; size_t totalBytes(){return total;} size_t usedBytes(){size_t u=0;for(auto&f:files)u+=f.second.size()+4096;return u;}
  bool exists(const char*p){return files.count(p);}
  File open(const char*p,const char*mode){File f;f.path=p;f.w=mode[0]=='w';
    if(f.w){files[p]="";f.ok=true;} else f.ok=files.count(p)>0; return f;}
  bool remove(const char*p){return files.erase(p)>0;}
  bool rename(const char*a,const char*b){if(!files.count(a))return false;files[b]=files[a];files.erase(a);return true;}
};
inline size_t File::size(){return LittleFS.files[path].size();}
inline size_t File::read(uint8_t*b,size_t n){auto&d=LittleFS.files[path];size_t k=min(n,d.size()-pos);memcpy(b,d.data()+pos,k);pos+=k;return k;}
inline size_t File::write(const uint8_t*b,size_t n){LittleFS.files[path].append((const char*)b,n);return n;}
