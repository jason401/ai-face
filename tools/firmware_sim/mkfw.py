import re,sys
src=open(sys.argv[1]).read().split('\n')
protos=[];first=None
for i,l in enumerate(src):
    if first is None and re.match(r'^typedef\b.*\(\*',l): first=i+1
    m=re.match(r'^([A-Za-z_][\w\s\*&]*?\b\w+\s*\([^;{]*\))\s*\{',l)
    if m:
        if first is None: first=i
        protos.append(m.group(1)+';')
txt='\n'.join(src[:first]+protos+src[first:])
txt=re.sub(r'^#include <Adafruit_GFX.h>','#include "stub.h"',txt,flags=re.M)
txt=re.sub(r'^#include <(Adafruit_GC9A01A|SPI|Preferences|math|LittleFS)\.h>\n','',txt,flags=re.M)
open(sys.argv[2],'w').write(txt)
