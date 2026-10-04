// AI Face.app: starts the Python controller (core/run_server.py) and shows the face in
// the macOS menu bar, so it is visible even when no ESP32 is plugged in.
//
// The Python app is the source of truth: it serves /emotions (every mood's animation
// frames) and /view (what the screen should show right now: face/clock, which mood, who
// chose it, timer, screen saver). This file only animates and draws that, small.
//
// Build: double-click "앱 빌드.command" (tools/build_app.sh; needs the Xcode Command Line Tools).
#import <Cocoa/Cocoa.h>
#include <math.h>

static NSTask *controller;

// ---------------------------------------------------------------------------
// Face animation, mirroring renderFace()/drawFace() in ESP32_Display.ino
// ---------------------------------------------------------------------------
enum { F_MOVE, F_HOLD, F_LEFT, F_RIGHT, F_X, F_Y, F_WIDTH, F_SMILE, F_OPEN,
       F_BROW, F_LIFT, F_EYES, F_TILT, F_FX, F_COLOR, F_SHAKE, F_COUNT };
static NSString *const FIELD_NAMES[F_COUNT] = {
    @"move", @"hold", @"left", @"right", @"x", @"y", @"width", @"smile", @"open",
    @"brow", @"lift", @"eyes", @"tilt", @"fx", @"color", @"shake"};
// Continuously interpolated fields, in pose order.
static const int CONT[11] = {F_LEFT, F_RIGHT, F_X, F_Y, F_WIDTH, F_SMILE, F_OPEN, F_BROW, F_LIFT, F_TILT, F_SHAKE};
enum { P_LEFT, P_RIGHT, P_X, P_Y, P_WIDTH, P_SMILE, P_OPEN, P_BROW, P_LIFT, P_TILT, P_SHAKE };
enum { EYE_NORMAL, EYE_HAPPY, EYE_CALM, EYE_CROSS, EYE_HEART, EYE_SPIRAL, EYE_STAR, EYE_DOT, EYE_BIG, EYE_SQUEEZE };
enum { FX_BLUSH = 1, FX_TEAR = 2, FX_SWEAT = 4 };
static const double PALETTE[8][3] = {{255,255,255},{255,150,190},{120,180,255},{255,225,90},
                                     {255,70,60},{130,220,110},{190,140,255},{255,160,60}};

typedef struct { int v[F_COUNT]; } Frame;
typedef struct { double v[11]; double rgb[3]; int eyes, fx; } Pose;

static Pose poseOf(Frame f) {
    Pose p;
    for (int i = 0; i < 11; i++) p.v[i] = f.v[CONT[i]];
    int c = MAX(0, MIN(7, f.v[F_COLOR]));
    for (int i = 0; i < 3; i++) p.rgb[i] = PALETTE[c][i];
    p.eyes = f.v[F_EYES]; p.fx = f.v[F_FX];
    return p;
}

static NSColor *rgbColor(double r, double g, double b) {
    return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1];
}

// Draws one face in a 240x240 coordinate space (y down), like the LCD. Features are drawn
// a bit bigger and with thicker lines than on the LCD so they read at menu bar size.
static void drawFaceFeatures(Pose p, double now) {
    NSColor *col = rgbColor(p.rgb[0], p.rgb[1], p.rgb[2]);
    double sx = p.v[P_SHAKE] * sin(now * 71.0), sy = p.v[P_SHAKE] * 0.6 * cos(now * 93.0);
    double ey = 90 + p.v[P_Y] + sy;
    double ex[2] = {80 + p.v[P_X] + sx, 160 + p.v[P_X] + sx};
    const double LINE = 9;

    if (p.fx & FX_BLUSH) {
        [rgbColor(240, 100, 140) setFill];
        for (int e = 0; e < 2; e++)
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(ex[e] - 15, ey + 16, 30, 11) xRadius:5 yRadius:5] fill];
    }
    for (int e = 0; e < 2; e++) {
        double open = p.v[P_LEFT + e], x = ex[e];
        [col setFill]; [col setStroke];
        if (p.eyes != EYE_NORMAL && open < 20) {   // closed eye
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x - 13, ey - 4, 26, 8) xRadius:4 yRadius:4] fill];
            continue;
        }
        NSBezierPath *path = [NSBezierPath bezierPath];
        path.lineWidth = LINE; path.lineCapStyle = NSLineCapStyleRound; path.lineJoinStyle = NSLineJoinStyleRound;
        switch (p.eyes) {
            case EYE_NORMAL: {
                double h = MAX(3, 17 * open / 100);
                [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x - 12, ey - h, 24, h * 2) xRadius:MIN(11, h) yRadius:MIN(11, h)] fill];
                break;
            }
            case EYE_HAPPY:   // ^
                [path moveToPoint:NSMakePoint(x - 12, ey + 5)];
                [path curveToPoint:NSMakePoint(x + 12, ey + 5) controlPoint1:NSMakePoint(x - 8, ey - 9) controlPoint2:NSMakePoint(x + 8, ey - 9)];
                [path stroke]; break;
            case EYE_CALM:    // u
                [path moveToPoint:NSMakePoint(x - 12, ey - 4)];
                [path curveToPoint:NSMakePoint(x + 12, ey - 4) controlPoint1:NSMakePoint(x - 8, ey + 10) controlPoint2:NSMakePoint(x + 8, ey + 10)];
                [path stroke]; break;
            case EYE_CROSS:
                [path moveToPoint:NSMakePoint(x - 10, ey - 10)]; [path lineToPoint:NSMakePoint(x + 10, ey + 10)];
                [path moveToPoint:NSMakePoint(x + 10, ey - 10)]; [path lineToPoint:NSMakePoint(x - 10, ey + 10)];
                [path stroke]; break;
            case EYE_HEART: {
                [rgbColor(255, 70, 120) setFill];
                NSBezierPath *h = [NSBezierPath bezierPath];
                [h moveToPoint:NSMakePoint(x, ey + 13)];
                [h curveToPoint:NSMakePoint(x, ey - 6) controlPoint1:NSMakePoint(x - 20, ey) controlPoint2:NSMakePoint(x - 12, ey - 18)];
                [h curveToPoint:NSMakePoint(x, ey + 13) controlPoint1:NSMakePoint(x + 12, ey - 18) controlPoint2:NSMakePoint(x + 20, ey)];
                [h fill]; break;
            }
            case EYE_SPIRAL: {
                double rot = now * 5.5;
                [path moveToPoint:NSMakePoint(x, ey)];
                for (double a = 0; a < 12.5; a += 0.3) [path lineToPoint:NSMakePoint(x + cos(a + rot) * a * 1.05, ey + sin(a + rot) * a * 1.05)];
                path.lineWidth = 4; [path stroke]; break;
            }
            case EYE_STAR: {
                for (int k = 0; k < 10; k++) {
                    double a = -M_PI / 2 + k * M_PI / 5, r = (k % 2) ? 6 : 15;
                    NSPoint pt = NSMakePoint(x + cos(a) * r, ey + sin(a) * r);
                    if (k == 0) [path moveToPoint:pt]; else [path lineToPoint:pt];
                }
                [path closePath]; [path fill]; break;
            }
            case EYE_DOT:
                [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - 6, ey - 6, 12, 12)] fill]; break;
            case EYE_BIG:
                [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - 14, ey - 14, 28, 28)] fill];
                [[NSColor blackColor] setFill];
                [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - 1, ey - 10, 9, 9)] fill];
                break;
            case EYE_SQUEEZE: {   // > <
                double d = e == 0 ? 1 : -1;
                [path moveToPoint:NSMakePoint(x - 8 * d, ey - 9)]; [path lineToPoint:NSMakePoint(x + 8 * d, ey)];
                [path lineToPoint:NSMakePoint(x - 8 * d, ey + 9)];
                [path stroke]; break;
            }
        }
    }
    [col setStroke];
    if (p.v[P_LIFT] >= 0.5) {   // eyebrows
        double bY = ey - 18 - p.v[P_LIFT] * 1.5, d = p.v[P_BROW] * 0.6;
        for (int e = 0; e < 2; e++) {
            double outer = e == 0 ? ex[e] - 12 : ex[e] + 12, inner = e == 0 ? ex[e] + 12 : ex[e] - 12;
            NSBezierPath *b = [NSBezierPath bezierPath];
            b.lineWidth = 7; b.lineCapStyle = NSLineCapStyleRound;
            [b moveToPoint:NSMakePoint(outer, bY + d)]; [b lineToPoint:NSMakePoint(inner, bY - d)];
            [b stroke];
        }
    }
    // Mouth: the same curve as the LCD (smile, mouth tilt, opening), stroked thick.
    double w = MAX(6, p.v[P_WIDTH] / 2), mx = 120 + p.v[P_X] * 0.3 + sx;
    NSBezierPath *top = [NSBezierPath bezierPath], *bottom = [NSBezierPath bezierPath];
    BOOL opened = p.v[P_OPEN] >= 4;
    for (int i = 0; i <= 24; i++) {
        double u = -1 + i / 12.0, curve = 1 - u * u;
        double y = 142 + sy + p.v[P_SMILE] * curve - p.v[P_TILT] * (u + 1) * 0.5, o = p.v[P_OPEN] * curve;
        NSPoint a = NSMakePoint(mx + u * w, y - o / 2), b = NSMakePoint(mx + u * w, y + o / 2);
        if (i == 0) { [top moveToPoint:a]; [bottom moveToPoint:b]; } else { [top lineToPoint:a]; [bottom lineToPoint:b]; }
    }
    if (opened) {   // filled open mouth: top edge forward, bottom edge back
        NSBezierPath *fill = [top copy];
        NSBezierPath *rev = [bottom bezierPathByReversingPath];
        for (NSInteger i = 0; i < rev.elementCount; i++) {
            NSPoint pts[3];
            [rev elementAtIndex:i associatedPoints:pts];
            [fill lineToPoint:pts[0]];
        }
        [fill closePath]; [col setFill]; [fill fill];
    }
    top.lineWidth = LINE; top.lineCapStyle = NSLineCapStyleRound; top.lineJoinStyle = NSLineJoinStyleRound;
    [top stroke];
    if (p.fx & FX_TEAR) {
        [rgbColor(90, 170, 255) setFill];
        double q = fmod(now / 1.5, 1.0);
        for (int e = 0; e < 2; e++)
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect((e ? ex[1] + 8 : ex[0] - 8) - 5, ey + 12 + q * 30, 10, 12)] fill];
    }
    if (p.fx & FX_SWEAT) {
        [rgbColor(90, 170, 255) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(178, 62 + fmod(now / 2.2, 1.0) * 10, 12, 15)] fill];
    }
}

static void drawClockHands(void) {
    NSDateComponents *c = [[NSCalendar currentCalendar] components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:[NSDate date]];
    double ha = ((c.hour % 12) + c.minute / 60.0) * M_PI / 6, ma = c.minute * M_PI / 30;
    [[NSColor whiteColor] setStroke];
    for (int k = 0; k < 12; k++) {   // hour marks
        double a = k * M_PI / 6;
        NSBezierPath *t = [NSBezierPath bezierPath]; t.lineWidth = k % 3 ? 5 : 9;
        [t moveToPoint:NSMakePoint(120 + sin(a) * 82, 120 - cos(a) * 82)];
        [t lineToPoint:NSMakePoint(120 + sin(a) * 96, 120 - cos(a) * 96)];
        [t stroke];
    }
    NSBezierPath *h = [NSBezierPath bezierPath]; h.lineWidth = 16; h.lineCapStyle = NSLineCapStyleRound;
    [h moveToPoint:NSMakePoint(120, 120)]; [h lineToPoint:NSMakePoint(120 + sin(ha) * 50, 120 - cos(ha) * 50)]; [h stroke];
    NSBezierPath *m = [NSBezierPath bezierPath]; m.lineWidth = 11; m.lineCapStyle = NSLineCapStyleRound;
    [m moveToPoint:NSMakePoint(120, 120)]; [m lineToPoint:NSMakePoint(120 + sin(ma) * 76, 120 - cos(ma) * 76)]; [m stroke];
    [rgbColor(255, 70, 60) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(110, 110, 20, 20)] fill];
}

// ---------------------------------------------------------------------------
// Mini campfire: the board's pixel-art fire on a 20x20 grid (12x12 cells in 240 space)
// ---------------------------------------------------------------------------
enum { MG = 20, MH = 15, FIRE_MAX = 36 };
static const double FIRE_PAL[9][3] = {{110,16,16},{160,28,12},{206,52,12},{238,90,16},{250,130,24},
                                      {255,168,40},{255,206,70},{255,236,140},{255,250,214}};
static uint8_t fireHeat[MH * MG];
static uint8_t fireLog[MG * MG];     // 0 none, 2 bark, 3 cut end
static uint32_t fireRng = 0x9E3779B9u;
static uint32_t fireRand(void) { fireRng ^= fireRng << 13; fireRng ^= fireRng >> 17; fireRng ^= fireRng << 5; return fireRng; }

static void fireLogLine(double x0, double y0, double x1, double y1) {
    for (int cy = 0; cy < MG; cy++) for (int cx = 0; cx < MG; cx++) {
        double dx = x1 - x0, dy = y1 - y0, l = dx * dx + dy * dy;
        double t = MAX(0.0, MIN(1.0, ((cx - x0) * dx + (cy - y0) * dy) / l));
        double ex = x0 + t * dx - cx, ey = y0 + t * dy - cy;
        if (sqrt(ex * ex + ey * ey) <= 0.7) fireLog[cy * MG + cx] = (t <= 0 || t >= 1) ? 3 : 2;
    }
}

static void fireStep(void) {
    for (int x = 0; x < MG; x++) {   // fuel row: hottest in the middle, flickering
        double d = fabs(x - 9.5) / 4.2;
        int h = d < 1 ? (int)(FIRE_MAX * (1 - 0.35 * d * d)) - (int)(fireRand() % 9) + ((fireRand() & 15) == 0 ? 6 : 0) : 0;
        fireHeat[(MH - 1) * MG + x] = MAX(0, MIN(FIRE_MAX, h));
    }
    // Heat rises with a random sideways drift, cools, and is squeezed toward the middle.
    for (int y = 1; y < MH; y++) for (int x = 0; x < MG; x++) {
        int p = fireHeat[y * MG + x];
        uint32_t r = fireRand();
        int nx = MAX(0, MIN(MG - 1, x + (int)(r % 3) - 1));
        int half = 1 + (y * 4) / MH, off = abs(nx * 2 - 19) / 2;
        int cool = 1 + ((r >> 3) & 1);
        if (off > half) cool += 1 + ((r >> 5) & 1);
        if (y < 5) cool += ((r >> 7) % 3) == 0;
        int h = MAX(0, p - cool);
        uint8_t *d = &fireHeat[(y - 1) * MG + nx];
        *d = (uint8_t)((h * 3 + *d) / 4);
    }
}

static void drawFire(void) {
    static BOOL ready = NO;
    if (!ready) { fireLogLine(5, 17, 14, 14); fireLogLine(6, 14, 15, 17); ready = YES; }
    for (int cy = 0; cy < MG; cy++) for (int cx = 0; cx < MG; cx++) {
        NSColor *c;
        int h = cy < MH ? fireHeat[cy * MG + cx] : 0;
        if (fireLog[cy * MG + cx] == 2) c = rgbColor(104, 58, 30);
        else if (fireLog[cy * MG + cx] == 3) c = rgbColor(214, 160, 98);
        else if (h >= 5) { const double *f = FIRE_PAL[MIN(8, (h - 5) * 9 / (FIRE_MAX - 4))]; c = rgbColor(f[0], f[1], f[2]); }
        else if (cy < 15) c = rgbColor(10 + cy, 12 + cy / 2, 30 + cy);   // night sky
        else {   // ground lit by the fire
            double g = MAX(0.0, 1 - pow((cx - 9.5) / 8, 2) - pow((cy - 15.5) / 3, 2)) * 0.6;
            c = rgbColor(34 + (150 - 34) * g, 22 + (70 - 22) * g, 18 + (24 - 18) * g);
        }
        [c setFill];
        NSRectFill(NSMakeRect(cx * 12, cy * 12, 12.4, 12.4));   // slight overlap: no seams when scaled
    }
}

// ---------------------------------------------------------------------------
// Menu bar item
// ---------------------------------------------------------------------------
@protocol ControlOpener
- (void)openControlWindow;
@end

@interface FaceItem : NSObject <NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *item;
@property(nonatomic, strong) NSURL *base;            // http://127.0.0.1:<port>/
@property(nonatomic, strong) NSDictionary *moods;    // id -> {name, frames}
@property(nonatomic, copy) NSString *emotion, *kind, *owner, *label;
@property(nonatomic, strong) NSMenuItem *titleItem, *loginItem;
@property(nonatomic, weak) id<ControlOpener> openTarget;
@end

@implementation FaceItem {
    Frame frames[24];
    int frameCount, frameIndex;
    Pose from, pose;
    double started;
    double timerEnd, timerTotal;     // seconds since reference date; 0 = no timer
    int timerColor;
    NSTimer *drawTimer, *pollTimer;
    BOOL polling;
}

- (instancetype)init {
    if ((self = [super init])) {
        _item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
        _item.button.toolTip = @"AI Face";
        _kind = @"face"; _owner = @"user"; _emotion = @""; _label = @"시작하는 중…";
        Frame sleeping = {{600, 2000, 0, 0, 0, 2, 40, 6, 0, 0, 0, 2, 0, 0, 0, 0}};   // until moods arrive
        frames[0] = sleeping; frameCount = 1; frameIndex = 0;
        from = pose = poseOf(sleeping); started = [NSDate timeIntervalSinceReferenceDate];
        [self buildMenu];
        drawTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 12 target:self selector:@selector(tick) userInfo:nil repeats:YES];
        drawTimer.tolerance = 0.02;
        [self tick];
    }
    return self;
}

- (void)buildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    _titleItem = [[NSMenuItem alloc] initWithTitle:_label action:nil keyEquivalent:@""];
    _titleItem.enabled = NO;
    [menu addItem:_titleItem];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"컨트롤러 열기" action:@selector(openController) keyEquivalent:@"o"];
    open.target = self; [menu addItem:open];
    _loginItem = [[NSMenuItem alloc] initWithTitle:@"로그인할 때 자동 실행" action:@selector(toggleLogin) keyEquivalent:@""];
    _loginItem.target = self; [menu addItem:_loginItem];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"AI Face 종료" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp; [menu addItem:quit];
    _item.menu = menu;
}

- (void)menuWillOpen:(NSMenu *)menu {
    _titleItem.title = _label;
    _loginItem.state = [[NSFileManager defaultManager] fileExistsAtPath:[self agentPath]] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)openController {
    [_openTarget openControlWindow];
}

// Launch at login via a per-user LaunchAgent (starts in the background, no browser window).
- (NSString *)agentPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/local.aiface.plist"];
}
- (void)toggleLogin {
    NSString *path = [self agentPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return;
    }
    NSString *exe = [[NSBundle mainBundle] executablePath];
    NSDictionary *plist = @{@"Label": @"local.aiface",
                            @"ProgramArguments": @[exe, @"--background"],
                            @"RunAtLoad": @YES,
                            @"ProcessType": @"Interactive"};
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [plist writeToFile:path atomically:YES];
}

- (void)setBase:(NSURL *)base {
    _base = base;
    [self poll];
    pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    pollTimer.tolerance = 0.2;
}

- (void)fetch:(NSString *)path done:(void (^)(id json))done {
    NSURL *url = [NSURL URLWithString:path relativeToURL:_base];
    NSURLRequest *req = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
    }] resume];
}

- (void)poll {
    if (!_base || polling) return;
    polling = YES;
    if (!_moods) {
        [self fetch:@"emotions" done:^(id json) {
            if ([json isKindOfClass:[NSArray class]]) {
                NSMutableDictionary *m = [NSMutableDictionary dictionary];
                for (NSDictionary *mood in json) if ([mood isKindOfClass:[NSDictionary class]] && mood[@"id"]) m[mood[@"id"]] = mood;
                self.moods = m;
                NSString *e = self.emotion; self.emotion = @""; [self showEmotion:e];
            }
        }];
    }
    [self fetch:@"view" done:^(id json) {
        self->polling = NO;
        if (![json isKindOfClass:[NSDictionary class]]) return;
        [self apply:json];
    }];
}

- (void)apply:(NSDictionary *)v {
    NSString *kind = [v[@"kind"] isKindOfClass:[NSString class]] ? v[@"kind"] : @"face";
    if ([kind isEqualToString:@"fire"] && ![_kind isEqualToString:@"fire"])
        for (int i = 0; i < 20; i++) fireStep();   // start with the flames already up
    NSString *owner = [v[@"owner"] isKindOfClass:[NSString class]] ? v[@"owner"] : @"user";
    _kind = kind; _owner = owner;
    if ([v[@"emotion"] isKindOfClass:[NSString class]]) [self showEmotion:v[@"emotion"]];
    NSDictionary *t = [v[@"timer"] isKindOfClass:[NSDictionary class]] ? v[@"timer"] : nil;
    double now = [NSDate timeIntervalSinceReferenceDate];
    if (t) {
        timerEnd = now + [t[@"left"] doubleValue];
        timerTotal = MAX(1, [t[@"total"] doubleValue]);
        NSArray *names = @[@"white", @"pink", @"blue", @"yellow", @"red", @"green", @"purple", @"orange"];
        NSUInteger c = [names indexOfObject:t[@"color"] ?: @"blue"];
        timerColor = c == NSNotFound ? 2 : (int)c;
    } else timerEnd = 0;
    NSString *who = [owner isEqualToString:@"claude"] ? @"Claude" : [owner isEqualToString:@"gpt"] ? @"GPT" : @"앱";
    NSString *name = [v[@"name"] isKindOfClass:[NSString class]] ? v[@"name"] : @"";
    NSString *board = [v[@"board"] boolValue] ? @"보드 연결됨" : @"보드 없음";
    _label = [NSString stringWithFormat:@"%@ · %@ · %@", name.length ? name : @"대기", who, board];
    _item.button.toolTip = _label;
}

- (void)showEmotion:(NSString *)emotion {
    if ([emotion isEqualToString:_emotion]) return;
    NSDictionary *mood = _moods[emotion];
    if (!mood) { _emotion = emotion; return; }   // frames not loaded yet: retried after /emotions
    NSArray *list = mood[@"frames"];
    int n = 0;
    for (NSDictionary *f in list) {
        if (n >= 24 || ![f isKindOfClass:[NSDictionary class]]) break;
        for (int k = 0; k < F_COUNT; k++) frames[n].v[k] = [f[FIELD_NAMES[k]] intValue];
        if (frames[n].v[F_MOVE] < 1) frames[n].v[F_MOVE] = 1;
        n++;
    }
    if (!n) return;
    _emotion = emotion;
    frameCount = n; frameIndex = 0;
    from = pose; started = [NSDate timeIntervalSinceReferenceDate];
}

// Advance the animation (same timing as the LCD) and redraw the menu bar image.
- (void)tick {
    double now = [NSDate timeIntervalSinceReferenceDate];
    Frame f = frames[frameIndex];
    double dt = (now - started) * 1000, t = MIN(1.0, dt / f.v[F_MOVE]);
    t = t * t * (3 - 2 * t);
    Pose target = poseOf(f);
    for (int i = 0; i < 11; i++) pose.v[i] = from.v[i] + (target.v[i] - from.v[i]) * t;
    for (int i = 0; i < 3; i++) pose.rgb[i] = from.rgb[i] + (target.rgb[i] - from.rgb[i]) * t;
    pose.eyes = t < 0.5 ? from.eyes : target.eyes;
    pose.fx = t < 0.5 ? from.fx : target.fx;
    if (dt >= f.v[F_MOVE] + f.v[F_HOLD]) { from = pose; frameIndex = (frameIndex + 1) % frameCount; started = now; }
    if ([_kind isEqualToString:@"fire"]) fireStep();
    [self redraw:now];
}

- (void)redraw:(double)now {
    CGFloat side = [[NSStatusBar systemStatusBar] thickness];
    CGFloat d = side - 4;   // circle diameter in points
    Pose p = pose;
    NSString *kind = _kind, *owner = _owner;
    double tEnd = timerEnd, tTotal = timerTotal; int tCol = timerColor;
    NSImage *img = [NSImage imageWithSize:NSMakeSize(side, side) flipped:YES drawingHandler:^BOOL(NSRect rect) {
        NSAffineTransform *tf = [NSAffineTransform transform];
        [tf translateXBy:(side - d) / 2 yBy:(side - d) / 2];
        [tf scaleBy:d / 240.0];
        [tf concat];
        [[NSColor blackColor] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 240, 240)] fill];
        if ([kind isEqualToString:@"fire"]) {   // clipped to the circle, under the ring
            [NSGraphicsContext saveGraphicsState];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 240, 240)] addClip];
            drawFire();
            [NSGraphicsContext restoreGraphicsState];
        }
        // Features larger than on the LCD (about the face center) so they read at this size.
        [NSGraphicsContext saveGraphicsState];
        NSAffineTransform *zoom = [NSAffineTransform transform];
        [zoom translateXBy:120 yBy:118]; [zoom scaleBy:1.3]; [zoom translateXBy:-120 yBy:-118];
        BOOL isClock = [kind isEqualToString:@"clock"], isFire = [kind isEqualToString:@"fire"];
        if (!isClock && !isFire) [zoom concat];
        if (isClock) drawClockHands(); else if (!isFire) drawFaceFeatures(p, now);
        [NSGraphicsContext restoreGraphicsState];
        // Border ring: who chose the face (Claude orange, GPT green, app white), or the timer.
        NSColor *ring = [owner isEqualToString:@"claude"] ? rgbColor(0xD9, 0x77, 0x57)
                      : [owner isEqualToString:@"gpt"] ? rgbColor(0x10, 0xA3, 0x7F) : rgbColor(255, 255, 255);
        const double RW = 20;
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(RW / 2, RW / 2, 240 - RW, 240 - RW)];
        circle.lineWidth = RW;
        if (tEnd > 0) {
            double left = MAX(0, tEnd - now), frac = left / tTotal;
            const double *c = PALETTE[tCol];
            [rgbColor(c[0] / 4, c[1] / 4, c[2] / 4) setStroke]; [circle stroke];
            if (left > 0 || fmod(now, 0.8) < 0.4) {   // blink when time is up
                NSBezierPath *arc = [NSBezierPath bezierPath];
                // Remaining part, ending at 12 o'clock (y is down: angles run clockwise).
                [arc appendBezierPathWithArcWithCenter:NSMakePoint(120, 120) radius:120 - RW / 2
                                            startAngle:-90 - 360 * (left > 0 ? frac : 1) endAngle:-90 clockwise:NO];
                arc.lineWidth = RW;
                [rgbColor(c[0], c[1], c[2]) setStroke]; [arc stroke];
            }
        } else {
            [ring setStroke]; [circle stroke];
        }
        return YES;
    }];
    img.template = NO;   // keep the colors (a template image would be drawn in black/white)
    _item.button.image = img;
}
@end

// ---------------------------------------------------------------------------
// App: runs the Python controller, opens its page, owns the menu bar item
// ---------------------------------------------------------------------------
@interface AppDelegate : NSObject <NSApplicationDelegate, ControlOpener>
@property(nonatomic, strong) NSURL *controlURL;
@property(nonatomic, strong) FaceItem *face;
- (void)openControlWindow;
@end

@implementation AppDelegate
- (void)openControlWindow {
    if (self.controlURL) {
        [[NSWorkspace sharedWorkspace] openURL:self.controlURL];
    }
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    [self openControlWindow];
    return YES;
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    if (controller.running) {
        [controller terminate];
    }
}
@end

static void showError(NSString *message) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"AI Face 실행 오류";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"확인"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        NSApp.delegate = delegate;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        // Started at login (LaunchAgent): stay in the menu bar, do not open the browser.
        BOOL background = NO;
        for (int i = 1; i < argc; i++) if (strcmp(argv[i], "--background") == 0) background = YES;
        NSString *root = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
        NSString *script = [root stringByAppendingPathComponent:@"core/run_server.py"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:script]) {
            showError(@"AI Face.app을 AI Face 프로젝트 폴더(core 폴더가 있는 곳)에 두세요.");
            return 1;
        }
        delegate.face = [[FaceItem alloc] init];
        delegate.face.openTarget = delegate;
        NSString *logPath = [root stringByAppendingPathComponent:@"app-launch.log"];
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
        NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:logPath];
        NSPipe *output = [NSPipe pipe];
        controller = [[NSTask alloc] init];
        controller.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
        controller.arguments = @[script, @"--no-browser"];
        controller.currentDirectoryURL = [NSURL fileURLWithPath:root];
        controller.standardOutput = output;
        controller.standardError = log ?: [NSFileHandle fileHandleWithNullDevice];
        __block NSMutableData *received = [NSMutableData data];
        __block BOOL opened = NO;
        output.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
            NSData *data = [handle availableData];
            if (!data.length) { handle.readabilityHandler = nil; return; }
            [received appendData:data];
            NSString *text = [[NSString alloc] initWithData:received encoding:NSUTF8StringEncoding];
            if (!opened && [text containsString:@"\n"]) {
                opened = YES;
                NSString *line = [[text componentsSeparatedByString:@"\n"] firstObject];
                NSURL *url = [NSURL URLWithString:line];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([url.host isEqualToString:@"127.0.0.1"] && [url.scheme isEqualToString:@"http"]) {
                        delegate.controlURL = url;
                        delegate.face.base = [NSURL URLWithString:[line stringByAppendingString:@"/"]];
                        if (!background && ![[NSWorkspace sharedWorkspace] openURL:url]) {
                            showError([@"Safari에서 이 주소를 열어 주세요: " stringByAppendingString:line]);
                        }
                    }
                });
            }
        };
        controller.terminationHandler = ^(NSTask *task) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (task.terminationStatus != 0) {
                    NSString *details = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
                    showError(details.length ? details : @"Python을 실행하지 못했습니다.");
                }
                [NSApp terminate:nil];
            });
        };
        NSError *error = nil;
        if (![controller launchAndReturnError:&error]) {
            showError(error.localizedDescription);
            return 1;
        }
        [NSApp run];
    }
    return 0;
}
