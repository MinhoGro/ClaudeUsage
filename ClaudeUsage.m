// Claude Code Usage Widget — native macOS desktop widget (Objective-C)
// Build: clang -framework Cocoa -framework Security -fobjc-arc -O2 ClaudeUsage.m -o ClaudeUsage
//
// Layout:
//   top    — subscription plan badge (Pro / Max / 免费) + 5h & 7d reset countdowns
//   middle — TWO iOS-battery-style rings:
//              left  = remaining % of the 5-hour window (all models)
//              right = remaining % of the 7-day window (total usage)
//   below  — any extra windows Claude reports (e.g. seven_day_opus) as bars
//
// Data sources, freshest wins (polled every 60 s, UI ticks every 15 s):
//   1. Anthropic OAuth usage API (api.anthropic.com/api/oauth/usage) using the
//      Claude Code login token from ~/.claude/.credentials.json or the
//      "Claude Code-credentials" Keychain item — independent of Claude Code
//      running. Read-only; never refreshes/rewrites the token.
//   2. ~/.claude/usage-cache.json written by statusline.py (statusLine hook).
// Plan name: auto-detected from the OAuth profile endpoint when possible,
// manual override via right-click menu.

#import <Cocoa/Cocoa.h>
#import <Security/Security.h>

// WidgetReloader is an @objc Swift class (WidgetReload.swift) in this app target.
// Forward-declare it rather than importing the generated -Swift.h (avoids build
// ordering issues). The Xcode build defines HAS_WIDGET_RELOADER and links the
// Swift symbol; the legacy clang build.sh defines neither, so it's skipped.
#ifdef HAS_WIDGET_RELOADER
@interface WidgetReloader : NSObject
+ (void)reload;
@end
#endif

// ─── Config ──────────────────────────────────────────────────────
static const CGFloat WIN_W = 260;
static const NSTimeInterval UI_TICK_SEC = 15;    // countdown redraw
static const NSTimeInterval POLL_SEC = 60;       // data fetch (API + cache reread)
static const double STALE_AFTER_SEC = 2 * 3600;  // warn when data older than this

static NSString *SupportDir(void) {
    NSString *base = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [base stringByAppendingPathComponent:@"ClaudeUsage"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
        withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}
static NSString *ConfigPath(void) {
    return [SupportDir() stringByAppendingPathComponent:@"config.json"];
}
static NSString *CachePath(void) {
    const char *env = getenv("CLAUDE_USAGE_CACHE");  // test override
    if (env && *env) return @(env);
    return [NSHomeDirectory() stringByAppendingPathComponent:@".claude/usage-cache.json"];
}

static NSMutableDictionary *LoadConfig(void) {
    NSData *d = [NSData dataWithContentsOfFile:ConfigPath()];
    if (d) {
        id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if ([o isKindOfClass:NSDictionary.class]) return [o mutableCopy];
    }
    return [@{ @"plan_name": @"Pro", @"pin_to_desktop": @YES } mutableCopy];
}
static void SaveConfig(NSDictionary *cfg) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:cfg
                    options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToFile:ConfigPath() atomically:YES];
}

// Desktop floating widget defaults to HIDDEN — the resident menu-bar item +
// native gallery widget are the primary UI. Re-show via the menu-bar menu.
static BOOL WidgetHidden(void) {
    id v = LoadConfig()[@"widget_hidden"];
    return v ? [v boolValue] : YES;
}

// ─── Data model ──────────────────────────────────────────────────
@interface LimitWindow : NSObject
@property (nonatomic, copy)   NSString *key;
@property (nonatomic, assign) double usedPct;    // 0-100, -1 unknown
@property (nonatomic, strong) NSDate *resetsAt;
@end
@implementation LimitWindow
- (double)remainingPct { return _usedPct < 0 ? -1 : MAX(0, MIN(100, 100 - _usedPct)); }
- (BOOL)expired { return _resetsAt && _resetsAt.timeIntervalSinceNow <= 0; }
@end

@interface UsageData : NSObject
@property (nonatomic, copy)   NSString *planName;
@property (nonatomic, copy)   NSString *modelName;
@property (nonatomic, strong) LimitWindow *fiveHour;            // all models, 5h
@property (nonatomic, strong) LimitWindow *sevenDay;            // total usage, 7d
@property (nonatomic, strong) NSArray<LimitWindow *> *extras;   // per-model etc.
@property (nonatomic, strong) NSDate *updatedAt;
@property (nonatomic, copy)   NSString *source;                 // "实时" / "缓存"
@property (nonatomic, assign) BOOL hasReal;
@end
@implementation UsageData
- (instancetype)init { if ((self = [super init])) _extras = @[]; return self; }
@end

// ─── Window parsing (shared by cache file & API) ─────────────────
static NSDate *ParseDateValue(id v) {
    if ([v isKindOfClass:NSNumber.class] && [v doubleValue] > 1e9) {
        double t = [v doubleValue];
        if (t > 1e12) t /= 1000.0;  // ms epoch
        return [NSDate dateWithTimeIntervalSince1970:t];
    }
    if ([v isKindOfClass:NSString.class]) {
        static NSISO8601DateFormatter *f1, *f2;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            f1 = [NSISO8601DateFormatter new];
            f1.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                               NSISO8601DateFormatWithFractionalSeconds;
            f2 = [NSISO8601DateFormatter new];
            f2.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        });
        NSDate *d = [f1 dateFromString:v] ?: [f2 dateFromString:v];
        if (d) return d;
        double t = [v doubleValue];
        if (t > 1e9) { if (t > 1e12) t /= 1000.0; return [NSDate dateWithTimeIntervalSince1970:t]; }
    }
    return nil;
}

static LimitWindow *ParseWindow(NSString *key, NSDictionary *w) {
    if (![w isKindOfClass:NSDictionary.class]) return nil;
    LimitWindow *lw = [LimitWindow new];
    lw.key = key;
    lw.usedPct = -1;
    id p = w[@"used_percentage"] ?: w[@"utilization"] ?: w[@"used_pct"];
    if ([p isKindOfClass:NSNumber.class] && [p doubleValue] >= 0)
        lw.usedPct = MIN(100, [p doubleValue]);
    lw.resetsAt = ParseDateValue(w[@"resets_at"] ?: w[@"reset_at"] ?: w[@"resets"]);
    return lw;
}

// Distribute a {key: window} dict into the UsageData slots.
static void FillFromWindows(UsageData *u, NSDictionary *windows) {
    NSMutableArray *extras = [NSMutableArray new];
    for (NSString *key in windows) {
        LimitWindow *lw = ParseWindow(key, windows[key]);
        if (!lw || lw.usedPct < 0) continue;
        u.hasReal = YES;
        NSString *k = key.lowercaseString;
        BOOL perModel = [k containsString:@"opus"] || [k containsString:@"sonnet"] ||
                        [k containsString:@"haiku"] || [k containsString:@"fable"];
        if (!perModel && ([k isEqualToString:@"five_hour"] || [k containsString:@"session"]))
            u.fiveHour = lw;
        else if (!perModel && ([k isEqualToString:@"seven_day"] || [k containsString:@"week"]))
            u.sevenDay = lw;
        else
            [extras addObject:lw];
    }
    [extras sortUsingComparator:^NSComparisonResult(LimitWindow *a, LimitWindow *b) {
        return [a.key compare:b.key];
    }];
    u.extras = extras;
}

static UsageData *LoadUsageFromCacheFile(void) {
    UsageData *u = [UsageData new];
    u.source = @"缓存";
    NSData *d = [NSData dataWithContentsOfFile:CachePath()];
    if (!d) return u;
    id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![o isKindOfClass:NSDictionary.class]) return u;
    NSDictionary *j = o;
    if ([j[@"model"] isKindOfClass:NSString.class]) u.modelName = j[@"model"];
    u.updatedAt = ParseDateValue(j[@"updated_at"]);
    NSDictionary *windows = [j[@"windows"] isKindOfClass:NSDictionary.class] ? j[@"windows"] : nil;
    if (!windows) {
        NSMutableDictionary *m = [NSMutableDictionary new];
        if (j[@"five_hour"]) m[@"five_hour"] = j[@"five_hour"];
        if (j[@"seven_day"]) m[@"seven_day"] = j[@"seven_day"];
        windows = m;
    }
    FillFromWindows(u, windows);
    return u;
}

// Persist API-fetched windows into the shared cache file so the WidgetKit
// widget (sandboxed, read-only) sees minute-fresh data even with CC closed.
static void PersistWindowsToCache(NSDictionary *windows) {
    if (!windows.count) return;
    NSString *path = CachePath();
    NSMutableDictionary *j = [NSMutableDictionary new];
    NSData *old = [NSData dataWithContentsOfFile:path];
    if (old) {
        id o = [NSJSONSerialization JSONObjectWithData:old options:0 error:nil];
        if ([o isKindOfClass:NSDictionary.class]) j = [o mutableCopy];
    }
    j[@"updated_at"] = @((long long)NSDate.date.timeIntervalSince1970);
    j[@"windows"] = windows;
    j[@"source"] = @"api";
    if (windows[@"five_hour"]) j[@"five_hour"] = windows[@"five_hour"];
    if (windows[@"seven_day"]) j[@"seven_day"] = windows[@"seven_day"];
    NSData *d = [NSJSONSerialization dataWithJSONObject:j options:0 error:nil];
    if (!d) return;
    NSString *tmp = [path stringByAppendingString:@".tmp"];
    if ([d writeToFile:tmp atomically:NO])
        rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation);
}

// WidgetKit extensions are sandboxed and can read ONLY their own container.
// We (non-sandboxed) mirror the live usage JSON + plan name into the widget's
// container so it needs no file-access entitlement (hence no provisioning
// profile — just a Team-ID signature). Path mirrors the sandbox layout:
//   ~/Library/Containers/<widget-id>/Data/Library/Application Support/ClaudeUsage/usage.json
static NSString *const kWidgetBundleID = @"com.mininghall.ClaudeUsage.widget";
static void MirrorToWidgetContainer(NSString *planName) {
    NSData *cache = [NSData dataWithContentsOfFile:CachePath()];
    if (!cache) return;
    id o = [NSJSONSerialization JSONObjectWithData:cache options:0 error:nil];
    if (![o isKindOfClass:NSDictionary.class]) return;
    NSMutableDictionary *j = [o mutableCopy];
    if (planName.length) j[@"plan"] = planName;

    NSString *dir = [NSHomeDirectory() stringByAppendingFormat:
        @"/Library/Containers/%@/Data/Library/Application Support/ClaudeUsage", kWidgetBundleID];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"usage.json"];
    NSData *d = [NSJSONSerialization dataWithJSONObject:j options:0 error:nil];
    if (!d) return;
    NSString *tmp = [path stringByAppendingString:@".tmp"];
    if ([d writeToFile:tmp atomically:NO])
        rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation);
}

// ─── OAuth token lookup (read-only) ──────────────────────────────
// 1) ~/.claude/.credentials.json  2) Keychain "Claude Code-credentials".
// Returns nil if absent or expired. Never writes anything back.
// *deniedOut is set when the user refused the Keychain prompt, so the
// caller can stop re-prompting every poll.
static NSString *FindOAuthToken(BOOL allowKeychain, BOOL *deniedOut) {
    NSData *blob = [NSData dataWithContentsOfFile:
        [NSHomeDirectory() stringByAppendingPathComponent:@".claude/.credentials.json"]];
    if (!blob && allowKeychain) {
        NSDictionary *q = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: @"Claude Code-credentials",
            (__bridge id)kSecReturnData: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
        };
        CFTypeRef out = NULL;
        OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &out);
        if (st == errSecSuccess && out)
            blob = CFBridgingRelease(out);
        else if (st != errSecItemNotFound && deniedOut)
            *deniedOut = YES;  // user hit Deny (or access blocked) — back off
    }
    if (!blob) return nil;
    id o = [NSJSONSerialization JSONObjectWithData:blob options:0 error:nil];
    if (![o isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *oauth = [o[@"claudeAiOauth"] isKindOfClass:NSDictionary.class] ? o[@"claudeAiOauth"] : nil;
    NSString *tok = oauth[@"accessToken"];
    if (![tok isKindOfClass:NSString.class] || !tok.length) return nil;
    NSDate *exp = ParseDateValue(oauth[@"expiresAt"]);
    if (exp && exp.timeIntervalSinceNow < 60) return nil;  // expired — let CC renew it
    return tok;
}

// ─── Formatting / colors ─────────────────────────────────────────
static NSString *RowLabel(NSString *key) {
    NSString *k = key.lowercaseString;
    NSString *base = @"";
    if ([k containsString:@"opus"]) base = @"Opus";
    else if ([k containsString:@"sonnet"]) base = @"Sonnet";
    else if ([k containsString:@"haiku"]) base = @"Haiku";
    else if ([k containsString:@"fable"]) base = @"Fable";
    else {
        NSString *s = [[key stringByReplacingOccurrencesOfString:@"seven_day_" withString:@""]
                          stringByReplacingOccurrencesOfString:@"five_hour_" withString:@""];
        base = s.length ? s.capitalizedString : key;
    }
    if ([k containsString:@"five_hour"] || [k containsString:@"session"])
        return [base stringByAppendingString:@" · 5小时"];
    return [base stringByAppendingString:@" · 7天"];
}

static NSString *FmtCountdown(NSDate *reset) {
    if (!reset) return @"—";
    double s = reset.timeIntervalSinceNow;
    if (s <= 0) return @"已重置";
    int days = (int)(s / 86400); s -= days * 86400;
    int hrs  = (int)(s / 3600);  s -= hrs * 3600;
    int mins = (int)MAX(1, s / 60);
    if (days > 0) return [NSString stringWithFormat:@"%d天%dh", days, hrs];
    if (hrs  > 0) return [NSString stringWithFormat:@"%dh%dm", hrs, mins];
    return [NSString stringWithFormat:@"%dm", mins];
}
static NSString *FmtAgo(NSDate *t) {
    double s = -t.timeIntervalSinceNow;
    if (s < 90)    return @"刚刚";
    if (s < 3600)  return [NSString stringWithFormat:@"%d分钟前", (int)(s/60)];
    if (s < 86400) return [NSString stringWithFormat:@"%d小时前", (int)(s/3600)];
    return [NSString stringWithFormat:@"%d天前", (int)(s/86400)];
}

static NSColor *RemainColor(double rem) {
    if (rem < 0)  return [NSColor colorWithWhite:0.55 alpha:1];
    if (rem < 15) return [NSColor colorWithRed:1.00 green:0.27 blue:0.23 alpha:1];
    if (rem < 30) return [NSColor colorWithRed:1.00 green:0.62 blue:0.04 alpha:1];
    if (rem < 55) return [NSColor colorWithRed:1.00 green:0.84 blue:0.04 alpha:1];
    return [NSColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:1];
}
static NSColor *PlanColor(NSString *plan) {
    NSString *p = plan.lowercaseString;
    if ([p containsString:@"max"])  return [NSColor colorWithRed:0.95 green:0.66 blue:0.10 alpha:1];
    if ([p containsString:@"team"] || [p containsString:@"enter"])
                                    return [NSColor colorWithRed:0.66 green:0.42 blue:0.97 alpha:1];
    if ([p containsString:@"pro"])  return [NSColor colorWithRed:0.07 green:0.51 blue:0.96 alpha:1];
    return [NSColor colorWithWhite:0.42 alpha:1];
}

// ─── Layout metrics (top-based) ──────────────────────────────────
static const CGFloat PAD = 16;
static const CGFloat HEADER_H = 56;
static const CGFloat RING_R = 44, RING_LW = 10;
static const CGFloat RING_ZONE_H = 4 + 2*44 + 30;   // rings + labels below
static const CGFloat ROW_H = 27;
static const CGFloat FOOT_H = 26;

static CGFloat WidgetHeight(NSUInteger extraRows) {
    return HEADER_H + RING_ZONE_H + (extraRows ? 6 + extraRows * ROW_H : 0) + FOOT_H;
}

// ─── Widget view ─────────────────────────────────────────────────
@interface WidgetView : NSView
@property (nonatomic, strong) UsageData *data;
@property (nonatomic, copy) void (^onRightClick)(NSEvent *);
@end

@implementation WidgetView
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) { _data = [UsageData new]; }
    return self;
}
- (void)rightMouseDown:(NSEvent *)e { if (self.onRightClick) self.onRightClick(e); }
// React to the first click even while another app is active (instant drag).
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

- (CGFloat)Y:(CGFloat)top h:(CGFloat)h { return self.bounds.size.height - top - h; }

- (void)text:(NSString *)s font:(NSFont *)f color:(NSColor *)c x:(CGFloat)x topCY:(CGFloat)cy align:(int)align {
    if (!s) return;
    NSDictionary *a = @{ NSFontAttributeName: f, NSForegroundColorAttributeName: c };
    NSSize sz = [s sizeWithAttributes:a];
    CGFloat px = (align == 1) ? x - sz.width : (align == 2 ? x - sz.width/2 : x);
    [s drawAtPoint:NSMakePoint(px, [self Y:cy - sz.height/2 h:sz.height]) withAttributes:a];
}

// One battery ring: center (cx, topCY), big % inside, two label lines below.
- (void)ringAtX:(CGFloat)cx topCY:(CGFloat)cy window:(LimitWindow *)w
          title:(NSString *)title subtitle:(NSString *)subtitle {
    NSPoint c = NSMakePoint(cx, [self Y:cy h:0]);
    NSColor *dim = [NSColor colorWithWhite:0.55 alpha:1];

    NSBezierPath *track = [NSBezierPath bezierPath];
    [track appendBezierPathWithArcWithCenter:c radius:RING_R startAngle:0 endAngle:360];
    [[NSColor colorWithWhite:0.22 alpha:1] setStroke];
    track.lineWidth = RING_LW; [track stroke];

    double rem = -1;
    BOOL resetDone = NO;
    if (w) {
        if (w.expired) { rem = 100; resetDone = YES; }  // window rolled over, quota is back
        else rem = w.remainingPct;
    }

    if (rem > 0) {
        NSBezierPath *arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:c radius:RING_R
                                    startAngle:90 endAngle:90 - 3.6 * rem clockwise:YES];
        [RemainColor(rem) setStroke];
        arc.lineWidth = RING_LW; arc.lineCapStyle = NSLineCapStyleRound; [arc stroke];
    }

    if (rem >= 0) {
        [self text:[NSString stringWithFormat:@"%.0f%%", rem]
              font:[NSFont monospacedDigitSystemFontOfSize:21 weight:NSFontWeightBold]
             color:RemainColor(rem) x:cx topCY:cy - (resetDone ? 7 : 0) align:2];
        if (resetDone)
            [self text:@"已重置" font:[NSFont systemFontOfSize:8.5 weight:NSFontWeightMedium]
                 color:dim x:cx topCY:cy + 13 align:2];
    } else {
        [self text:@"—" font:[NSFont systemFontOfSize:21 weight:NSFontWeightBold]
             color:dim x:cx topCY:cy align:2];
    }

    [self text:title font:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
         color:NSColor.whiteColor x:cx topCY:cy + RING_R + 13 align:2];
    [self text:subtitle font:[NSFont systemFontOfSize:9 weight:NSFontWeightRegular]
         color:[NSColor colorWithWhite:0.45 alpha:1] x:cx topCY:cy + RING_R + 26 align:2];
}

- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    CGFloat W = b.size.width;
    UsageData *d = self.data;

    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:b xRadius:20 yRadius:20];
    [[NSColor colorWithRed:0.106 green:0.106 blue:0.118 alpha:0.97] setFill];
    [bg fill];

    NSColor *dim  = [NSColor colorWithWhite:0.55 alpha:1];
    NSColor *dim2 = [NSColor colorWithWhite:0.40 alpha:1];
    NSColor *white = NSColor.whiteColor;

    // ── Header: plan pill + reset countdowns ──
    NSString *plan = d.planName ?: @"—";
    NSFont *pillF = [NSFont systemFontOfSize:13 weight:NSFontWeightBold];
    NSSize pSz = [plan sizeWithAttributes:@{ NSFontAttributeName: pillF }];
    CGFloat pillW = pSz.width + 24, pillH = 26, pillTop = 14;
    NSRect pill = NSMakeRect(PAD, [self Y:pillTop h:pillH], pillW, pillH);
    [[PlanColor(plan) colorWithAlphaComponent:0.95] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:pillH/2 yRadius:pillH/2] fill];
    [self text:plan font:pillF color:white x:PAD + pillW/2 topCY:pillTop + pillH/2 align:2];
    [self text:@"订阅套餐" font:[NSFont systemFontOfSize:9 weight:NSFontWeightRegular]
         color:dim2 x:PAD + 2 topCY:pillTop + pillH + 9 align:0];

    NSFont *cdLbl = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    NSFont *cdVal = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
    CGFloat rx = W - PAD;
    NSDate *r5 = d.fiveHour.resetsAt, *r7 = d.sevenDay.resetsAt;
    [self text:@"5小时重置" font:cdLbl color:dim x:rx - 52 topCY:19 align:1];
    [self text:FmtCountdown(r5) font:cdVal color:(r5 ? white : dim) x:rx topCY:19 align:1];
    [self text:@"7天重置" font:cdLbl color:dim x:rx - 52 topCY:38 align:1];
    [self text:FmtCountdown(r7) font:cdVal color:(r7 ? white : dim) x:rx topCY:38 align:1];

    // ── Two rings ──
    CGFloat ringCY = HEADER_H + 4 + RING_R;
    [self ringAtX:W*0.27 topCY:ringCY window:d.fiveHour
            title:@"5小时剩余" subtitle:@"所有模型"];
    [self ringAtX:W*0.73 topCY:ringCY window:d.sevenDay
            title:@"7天剩余" subtitle:@"全部用量"];

    // ── Extra windows (per-model etc.) ──
    if (d.extras.count) {
        CGFloat rowTop = HEADER_H + RING_ZONE_H + 6;
        NSFont *rowLblF = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        NSFont *rowPctF = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold];
        for (LimitWindow *w in d.extras) {
            CGFloat cy = rowTop + ROW_H/2;
            double r = w.expired ? 100 : w.remainingPct;
            NSColor *col = RemainColor(r);
            [self text:RowLabel(w.key) font:rowLblF color:white x:PAD topCY:cy align:0];
            CGFloat bx = 108, bw = W - PAD - 46 - bx, bh = 6;
            NSRect tr = NSMakeRect(bx, [self Y:cy - bh/2 h:bh], bw, bh);
            [[NSColor colorWithWhite:1 alpha:0.13] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:tr xRadius:bh/2 yRadius:bh/2] fill];
            if (r > 0) {
                NSRect fr = tr; fr.size.width = MAX(bh, bw * r / 100.0);
                [col setFill];
                [[NSBezierPath bezierPathWithRoundedRect:fr xRadius:bh/2 yRadius:bh/2] fill];
            }
            [self text:[NSString stringWithFormat:@"%.0f%%", r]
                  font:rowPctF color:col x:W - PAD topCY:cy align:1];
            rowTop += ROW_H;
        }
    }

    // ── Footer: freshness + source ──
    NSString *foot;
    NSColor *footCol = dim2;
    if (!d.hasReal) {
        foot = @"暂无数据 · 在 Claude Code 里发条消息";
    } else {
        NSString *src = d.source ?: @"";
        foot = [NSString stringWithFormat:@"更新于%@ · %@",
                d.updatedAt ? FmtAgo(d.updatedAt) : @"—", src];
        if (d.modelName && d.extras.count == 0)
            foot = [foot stringByAppendingFormat:@" · %@", d.modelName];
        if (d.updatedAt && -d.updatedAt.timeIntervalSinceNow > STALE_AFTER_SEC) {
            foot = [@"⚠ " stringByAppendingString:foot];
            footCol = [NSColor colorWithRed:1.00 green:0.62 blue:0.04 alpha:0.85];
        }
    }
    [self text:foot font:[NSFont systemFontOfSize:9 weight:NSFontWeightRegular]
         color:footCol x:W/2 topCY:b.size.height - 13 align:2];
}
@end

// ─── Menu-bar dropdown panel ─────────────────────────────────────
// A COMPACT view for the system status menu: transparent background (blends
// with the menu material), semantic label colors (matches the menu items in
// light & dark), and HORIZONTAL BARS (no rings) for every quota — denser and
// less stacked than rings.
static const CGFloat MC_W = 264;
static CGFloat MenuCardHeight(NSUInteger extras) { return 86 + (2 + extras) * 26; }

// Apple's secondary/tertiaryLabelColor are tuned for vibrancy-backed views and
// render too faint when drawn manually on the menu's dark material. Use higher-
// contrast custom colors that still flip with light/dark.
static BOOL MenuIsDark(NSAppearance *ap) {
    return [[ap bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
            isEqualToString:NSAppearanceNameDarkAqua];
}
static NSColor *MenuSecondary(void) {
    return [NSColor colorWithName:@"cuMenuSecondary" dynamicProvider:^NSColor *(NSAppearance *ap) {
        return MenuIsDark(ap) ? [NSColor colorWithWhite:1.0 alpha:0.74] : [NSColor colorWithWhite:0.0 alpha:0.58];
    }];
}
static NSColor *MenuTertiary(void) {
    return [NSColor colorWithName:@"cuMenuTertiary" dynamicProvider:^NSColor *(NSAppearance *ap) {
        return MenuIsDark(ap) ? [NSColor colorWithWhite:1.0 alpha:0.58] : [NSColor colorWithWhite:0.0 alpha:0.46];
    }];
}

@interface MenuCardView : NSView
@property (nonatomic, strong) UsageData *data;
@end

@implementation MenuCardView
- (BOOL)isFlipped { return YES; }   // y grows downward — natural top-down layout

- (void)txt:(NSString *)s font:(NSFont *)f color:(NSColor *)c x:(CGFloat)x y:(CGFloat)y align:(int)align {
    if (!s) return;
    NSDictionary *a = @{ NSFontAttributeName: f, NSForegroundColorAttributeName: c };
    NSSize sz = [s sizeWithAttributes:a];
    CGFloat px = (align == 1) ? x - sz.width : (align == 2 ? x - sz.width/2 : x);
    [s drawAtPoint:NSMakePoint(px, y) withAttributes:a];
}
- (void)txtC:(NSString *)s font:(NSFont *)f color:(NSColor *)c cx:(CGFloat)cx cy:(CGFloat)cy {
    NSDictionary *a = @{ NSFontAttributeName: f, NSForegroundColorAttributeName: c };
    NSSize sz = [s sizeWithAttributes:a];
    [s drawAtPoint:NSMakePoint(cx - sz.width/2, cy - sz.height/2) withAttributes:a];
}

// label (secondary) + value (primary, bold) right-aligned at rightX, on one line
- (void)resetRowRight:(CGFloat)rightX y:(CGFloat)y label:(NSString *)label value:(NSString *)value {
    NSFont *lf = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    NSFont *vf = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold];
    NSDictionary *va = @{ NSFontAttributeName: vf };
    CGFloat vw = [value sizeWithAttributes:va].width;
    [self txt:value font:vf color:NSColor.labelColor x:rightX y:y align:1];
    [self txt:label font:lf color:MenuSecondary() x:rightX - vw - 6 y:y + 1 align:1];
}

// One horizontal bar row: "5小时剩余  [████░░]  26%", vertically centered at row top y (rowH 26).
- (void)barRow:(LimitWindow *)w label:(NSString *)label y:(CGFloat)y width:(CGFloat)W {
    const CGFloat PAD = 16, barX = 92, barH = 7;
    CGFloat barRight = W - PAD - 42, barW = barRight - barX, cy = y + 13;
    double rem = w ? (w.expired ? 100 : w.remainingPct) : -1;
    NSColor *col = (rem < 0) ? NSColor.tertiaryLabelColor : RemainColor(rem);

    NSFont *lf = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    CGFloat lh = [label sizeWithAttributes:@{NSFontAttributeName:lf}].height;
    [self txt:label font:lf color:NSColor.labelColor x:PAD y:cy - lh/2 align:0];

    NSRect tr = NSMakeRect(barX, cy - barH/2, barW, barH);
    [[NSColor tertiaryLabelColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:tr xRadius:barH/2 yRadius:barH/2] fill];
    if (rem > 0) {
        NSRect fr = tr; fr.size.width = MAX(barH, barW * rem / 100.0);
        [col setFill];
        [[NSBezierPath bezierPathWithRoundedRect:fr xRadius:barH/2 yRadius:barH/2] fill];
    }
    NSString *p = (rem < 0) ? @"—" : [NSString stringWithFormat:@"%.0f%%", rem];
    NSFont *pf = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightSemibold];
    CGFloat ph = [p sizeWithAttributes:@{NSFontAttributeName:pf}].height;
    [self txt:p font:pf color:col x:W - PAD y:cy - ph/2 align:1];
}

- (void)drawRect:(NSRect)dirty {
    UsageData *d = self.data;
    const CGFloat W = self.bounds.size.width, PAD = 16;

    // ── plan pill (top-left) ──
    NSString *plan = d.planName.length ? d.planName : @"—";
    NSFont *pillF = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
    CGFloat pillW = [plan sizeWithAttributes:@{NSFontAttributeName:pillF}].width + 20, pillH = 22;
    NSRect pill = NSMakeRect(PAD, 14, pillW, pillH);
    [PlanColor(plan) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:pillH/2 yRadius:pillH/2] fill];
    [self txtC:plan font:pillF color:NSColor.whiteColor cx:PAD + pillW/2 cy:14 + pillH/2];

    // ── reset countdowns (top-right, two lines) ──
    LimitWindow *fh = d.fiveHour, *sd = d.sevenDay;
    [self resetRowRight:W - PAD y:14 label:@"5小时重置"
                  value:(fh.resetsAt ? FmtCountdown(fh.resetsAt) : @"—")];
    [self resetRowRight:W - PAD y:31 label:@"7天重置"
                  value:(sd.resetsAt ? FmtCountdown(sd.resetsAt) : @"—")];

    // ── divider under header ──
    [[NSColor quaternaryLabelColor] setStroke];
    NSBezierPath *dl = [NSBezierPath bezierPath];
    [dl moveToPoint:NSMakePoint(PAD, 52)]; [dl lineToPoint:NSMakePoint(W - PAD, 52)];
    dl.lineWidth = 1; [dl stroke];

    // ── horizontal bar rows: 5小时 / 7天 / per-model ──
    CGFloat y = 60;
    [self barRow:fh label:@"5小时剩余" y:y width:W]; y += 26;
    [self barRow:sd label:@"7天剩余"  y:y width:W]; y += 26;
    for (LimitWindow *w in d.extras) { [self barRow:w label:RowLabel(w.key) y:y width:W]; y += 26; }

    // ── footer: freshness + source ──
    NSString *foot;
    if (!d || !d.hasReal) foot = @"暂无数据，等待刷新…";
    else foot = [NSString stringWithFormat:@"更新于%@%@",
                 d.updatedAt ? FmtAgo(d.updatedAt) : @"—",
                 d.source.length ? [@" · " stringByAppendingString:d.source] : @""];
    [self txt:foot font:[NSFont systemFontOfSize:9.5 weight:NSFontWeightRegular]
         color:MenuTertiary() x:PAD y:y + 2 align:0];
}
@end

// ─── App delegate ────────────────────────────────────────────────
@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) WidgetView *view;
@property (nonatomic, strong) NSTimer *uiTimer, *pollTimer;
@property (nonatomic, strong) UsageData *apiData;       // last successful API fetch
@property (nonatomic, strong) UsageData *latest;        // last presented data (for status menu)
@property (nonatomic, strong) NSStatusItem *statusItem; // resident menu-bar item
@property (nonatomic, copy)   NSString *detectedPlan;   // from OAuth profile
@property (nonatomic, assign) BOOL keychainDenied;      // user refused — stop prompting
@property (nonatomic, strong) NSDate *lastProfileFetch;
@property (nonatomic, strong) NSTimer *pingTimer;       // watches the widget refresh-button ping
@property (nonatomic, assign) double lastPingMtime;
@end

@implementation AppDelegate

- (void)applyWindowLevel {
    id v = LoadConfig()[@"pin_to_desktop"];
    BOOL pin = v ? [v boolValue] : YES;  // default: pinned to the desktop layer
    // NSNormalWindowLevel-1: visually on the desktop (above wallpaper and
    // icons, below every app window) like native macOS widgets, but still
    // receives mouse events — windows at the true desktop-icon level get
    // none (the WindowServer hands those clicks to Finder).
    self.window.level = pin ? (NSNormalWindowLevel - 1) : NSStatusWindowLevel;
}

// ── Floating-widget visibility (hideable; menu-bar item stays resident) ──
- (void)applyWidgetVisibility {
    if (WidgetHidden()) {
        [self.window orderOut:nil];
    } else {
        [self applyWindowLevel];
        [self.window orderFrontRegardless];
    }
}
- (void)toggleWidgetHidden:(id)s {
    NSMutableDictionary *cfg = LoadConfig();
    cfg[@"widget_hidden"] = @(!WidgetHidden());
    SaveConfig(cfg);
    [self applyWidgetVisibility];
}

// Menu-bar gauge: a battery-style ring whose filled arc = remaining 5-hour
// quota, quantized to 20% steps (0/20/40/60/80/100), with the brand spark in
// the center. Template image → alpha preserved through tinting, so the faint
// track + solid fill both render correctly in light/dark menu bars.
- (NSImage *)gaugeIconForRemaining:(double)rem {
    const CGFloat S = 18;
    double q = (rem < 0) ? -1 : round(rem / 20.0) * 20.0;   // nearest 20%
    NSImage *img = [NSImage imageWithSize:NSMakeSize(S, S) flipped:NO
                            drawingHandler:^BOOL(NSRect r) {
        NSPoint c = NSMakePoint(S/2, S/2);
        const CGFloat radius = 6.8, lw = 2.0;
        // faint full track
        [[NSColor colorWithWhite:0 alpha:0.26] setStroke];
        NSBezierPath *track = [NSBezierPath bezierPath];
        [track appendBezierPathWithArcWithCenter:c radius:radius startAngle:0 endAngle:360];
        track.lineWidth = lw; [track stroke];
        // solid fill arc = quantized remaining, from 12 o'clock clockwise
        if (q > 0) {
            [[NSColor colorWithWhite:0 alpha:1.0] setStroke];
            NSBezierPath *arc = [NSBezierPath bezierPath];
            [arc appendBezierPathWithArcWithCenter:c radius:radius
                                        startAngle:90 endAngle:90 - 3.6 * q clockwise:YES];
            arc.lineWidth = lw; arc.lineCapStyle = NSLineCapStyleRound; [arc stroke];
        }
        // brand spark in the center
        for (int i = 0; i < 6; i++) {
            CGFloat a = i * M_PI/3 + M_PI/6;
            NSBezierPath *ray = [NSBezierPath bezierPath];
            [ray moveToPoint:NSMakePoint(c.x + cos(a)*1.0, c.y + sin(a)*1.0)];
            [ray lineToPoint:NSMakePoint(c.x + cos(a)*2.9, c.y + sin(a)*2.9)];
            ray.lineWidth = 1.2; ray.lineCapStyle = NSLineCapStyleRound; [ray stroke];
        }
        return YES;
    }];
    img.template = YES;
    return img;
}

// ── Resident menu-bar status item ──
- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.imagePosition = NSImageLeading;
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    m.delegate = self;            // rebuilt on each open via menuNeedsUpdate:
    m.autoenablesItems = NO;
    self.statusItem.menu = m;
    [self updateStatusItem];      // sets the gauge image + % title
}

- (void)updateStatusItem {
    LimitWindow *fh = self.latest.fiveHour;
    double rem; NSString *t;
    if (!fh || fh.usedPct < 0) { rem = -1;  t = @" —"; }
    else if (fh.expired)       { rem = 100; t = @" 100%"; }
    else                       { rem = fh.remainingPct; t = [NSString stringWithFormat:@" %.0f%%", rem]; }
    self.statusItem.button.image = [self gaugeIconForRemaining:rem];
    self.statusItem.button.title = t;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != self.statusItem.menu) return;   // only the status menu is dynamic
    [menu removeAllItems];

    // Compact, menu-native panel (transparent bg + semantic colors + small
    // rings) — blends with the menu instead of a dark card dumped on top.
    UsageData *d = self.latest ?: [UsageData new];
    MenuCardView *card = [[MenuCardView alloc] initWithFrame:NSMakeRect(0, 0, MC_W, MenuCardHeight(d.extras.count))];
    card.data = d;
    NSMenuItem *cardItem = [[NSMenuItem alloc] init];
    cardItem.view = card;
    [menu addItem:cardItem];

    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *vis = [[NSMenuItem alloc] initWithTitle:(WidgetHidden() ? @"显示桌面组件" : @"隐藏桌面组件")
                        action:@selector(toggleWidgetHidden:) keyEquivalent:@""];
    vis.target = self; [menu addItem:vis];
    NSMenuItem *rf = [[NSMenuItem alloc] initWithTitle:@"立即刷新"
                        action:@selector(refreshNow:) keyEquivalent:@""];
    rf.target = self; [menu addItem:rf];
    NSMenuItem *q = [[NSMenuItem alloc] initWithTitle:@"退出 Claude 用量"
                        action:@selector(quit:) keyEquivalent:@""];
    q.target = self; [menu addItem:q];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSMutableDictionary *cfg = LoadConfig();
    CGFloat h = WidgetHeight(0);

    NSRect vis = NSScreen.mainScreen.visibleFrame;
    NSPoint o = NSMakePoint(NSMaxX(vis) - WIN_W - 24, NSMaxY(vis) - h - 24);
    if (cfg[@"window_x"] && cfg[@"window_y"])
        o = NSMakePoint([cfg[@"window_x"] doubleValue], [cfg[@"window_y"] doubleValue]);

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(o.x, o.y, WIN_W, h)
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.opaque = NO;
    self.window.backgroundColor = NSColor.clearColor;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorStationary |
                                     NSWindowCollectionBehaviorIgnoresCycle;
    self.window.movableByWindowBackground = YES;
    self.window.hasShadow = YES;
    self.window.delegate = self;
    [self applyWindowLevel];

    self.view = [[WidgetView alloc] initWithFrame:NSMakeRect(0, 0, WIN_W, h)];
    __weak typeof(self) ws = self;
    self.view.onRightClick = ^(NSEvent *e) { [ws showMenu:e]; };
    self.window.contentView = self.view;

    [self setupStatusItem];        // resident menu-bar item
    [self applyWidgetVisibility];  // shows the floating window unless hidden in config

    [self pollData];
    self.uiTimer = [NSTimer scheduledTimerWithTimeInterval:UI_TICK_SEC repeats:YES
                                                     block:^(NSTimer *t){ [ws presentFreshest]; }];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:POLL_SEC repeats:YES
                                                       block:^(NSTimer *t){ [ws pollData]; }];
    // Baseline the refresh-ping mtime ONCE, so only taps AFTER launch trigger a
    // fetch (a stale file from a previous run isn't mistaken for a fresh tap).
    NSDictionary *pa = [[NSFileManager defaultManager] attributesOfItemAtPath:[self pingPath] error:nil];
    self.lastPingMtime = pa ? [[pa fileModificationDate] timeIntervalSince1970] : 0;
    // Watch the widget's refresh-button "ping" (every 2 s; cheap file stat).
    self.pingTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES
                                                       block:^(NSTimer *t){ [ws checkRefreshPing]; }];
}

// The widget's refresh button writes ~/.../ClaudeUsage/refresh-ping into its
// container. When its mtime advances, fetch fresh data now and reload the widget.
- (NSString *)pingPath {
    return [NSHomeDirectory() stringByAppendingFormat:
        @"/Library/Containers/%@/Data/Library/Application Support/ClaudeUsage/refresh-ping", kWidgetBundleID];
}
- (void)checkRefreshPing {
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:[self pingPath] error:nil];
    if (!attr) return;
    double m = [[attr fileModificationDate] timeIntervalSince1970];
    if (m > self.lastPingMtime + 0.01) {
        self.lastPingMtime = m;
        [self pollData];   // fresh API fetch → presentFreshest → mirror updated
#ifdef HAS_WIDGET_RELOADER
        // Give the fetch a moment to land in the mirror, then push to the widget.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [WidgetReloader reload]; });
#endif
    }
}

- (void)windowDidMove:(NSNotification *)n {
    NSMutableDictionary *cfg = LoadConfig();
    cfg[@"window_x"] = @(self.window.frame.origin.x);
    cfg[@"window_y"] = @(self.window.frame.origin.y);
    SaveConfig(cfg);
}

// Pick freshest of (API data, cache file), apply plan override, render.
- (void)presentFreshest {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        UsageData *file = LoadUsageFromCacheFile();
        UsageData *best = file;
        UsageData *api = self.apiData;
        if (api && api.hasReal &&
            (!file.hasReal || !file.updatedAt ||
             (api.updatedAt && [api.updatedAt timeIntervalSinceDate:file.updatedAt] >= 0)))
            best = api;
        if (!best.modelName) best.modelName = file.modelName;

        NSMutableDictionary *cfg = LoadConfig();
        BOOL manual = [cfg[@"plan_manual"] boolValue];
        NSString *detected = self.detectedPlan ?:
            ([cfg[@"detected_plan"] isKindOfClass:NSString.class] ? cfg[@"detected_plan"] : nil);
        best.planName = (!manual && detected.length) ? detected
                       : ([cfg[@"plan_name"] isKindOfClass:NSString.class] ? cfg[@"plan_name"] : @"—");

        // Feed the native WidgetKit widget (reads only its own container).
        MirrorToWidgetContainer(best.planName);

        dispatch_async(dispatch_get_main_queue(), ^{
            self.latest = best;
            [self updateStatusItem];   // keep the menu-bar % current
            CGFloat h = WidgetHeight(best.extras.count);
            if (fabs(h - self.window.frame.size.height) > 0.5) {
                NSRect f = self.window.frame;
                f.origin.y = NSMaxY(f) - h; f.size.height = h;
                [self.window setFrame:f display:YES];
                [self.view setFrameSize:NSMakeSize(WIN_W, h)];
            }
            self.view.data = best;
            self.view.needsDisplay = YES;
        });
    });
}

// 60 s poll: hit the OAuth usage endpoint if a login token exists.
- (void)pollData {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL denied = NO;
        NSString *tok = FindOAuthToken(!self.keychainDenied, &denied);
        if (denied) self.keychainDenied = YES;
        if (!tok) { [self presentFreshest]; return; }

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:@"https://api.anthropic.com/api/oauth/usage"]];
        [req setValue:[@"Bearer " stringByAppendingString:tok] forHTTPHeaderField:@"Authorization"];
        [req setValue:@"oauth-2025-04-20" forHTTPHeaderField:@"anthropic-beta"];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.timeoutInterval = 15;

        [[NSURLSession.sharedSession dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
            if (!err && code == 200 && data) {
                id o = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([o isKindOfClass:NSDictionary.class]) {
                    UsageData *u = [UsageData new];
                    u.source = @"实时";
                    u.updatedAt = [NSDate date];
                    // Accept {key:{...}} at top level or under "rate_limits"/"windows".
                    NSDictionary *j = o;
                    NSDictionary *wins = nil;
                    for (NSString *k in @[@"windows", @"rate_limits", @"usage"]) {
                        if ([j[k] isKindOfClass:NSDictionary.class]) { wins = j[k]; break; }
                    }
                    if (!wins) {
                        NSMutableDictionary *m = [NSMutableDictionary new];
                        for (NSString *k in j)
                            if ([j[k] isKindOfClass:NSDictionary.class] &&
                                (j[k][@"utilization"] || j[k][@"used_percentage"] || j[k][@"resets_at"]))
                                m[k] = j[k];
                        wins = m;
                    }
                    FillFromWindows(u, wins);
                    if (u.hasReal) {
                        self.apiData = u;
                        PersistWindowsToCache(wins);
                    }
                }
            }
            [self maybeFetchProfile:tok];
            [self presentFreshest];
        }] resume];
    });
}

// Plan auto-detect: OAuth profile, at most once per 6 h. Best-effort.
- (void)maybeFetchProfile:(NSString *)tok {
    if (self.lastProfileFetch && -self.lastProfileFetch.timeIntervalSinceNow < 6*3600) return;
    self.lastProfileFetch = [NSDate date];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.anthropic.com/api/oauth/profile"]];
    [req setValue:[@"Bearer " stringByAppendingString:tok] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"oauth-2025-04-20" forHTTPHeaderField:@"anthropic-beta"];
    req.timeoutInterval = 15;
    [[NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || [(NSHTTPURLResponse *)resp statusCode] != 200 || !data) return;
        id o = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![o isKindOfClass:NSDictionary.class]) return;
        NSDictionary *acct = [o[@"account"] isKindOfClass:NSDictionary.class] ? o[@"account"] : @{};
        NSDictionary *org  = [o[@"organization"] isKindOfClass:NSDictionary.class] ? o[@"organization"] : @{};
        NSString *plan = nil;
        if ([acct[@"has_claude_max"] boolValue]) plan = @"Max";
        else if ([acct[@"has_claude_pro"] boolValue]) plan = @"Pro";
        else {
            NSString *t = [org[@"organization_type"] isKindOfClass:NSString.class] ? org[@"organization_type"] : @"";
            if ([t containsString:@"max"]) plan = @"Max";
            else if ([t containsString:@"pro"]) plan = @"Pro";
            else if (t.length) plan = @"免费";
        }
        if (plan) {
            self.detectedPlan = plan;
            NSMutableDictionary *cfg = LoadConfig();
            if (![plan isEqualToString:cfg[@"detected_plan"]]) {
                cfg[@"detected_plan"] = plan;
                SaveConfig(cfg);
            }
            [self presentFreshest];
        }
    }] resume];
}

// ── Right-click menu ──
- (void)showMenu:(NSEvent *)e {
    NSMutableDictionary *cfg = LoadConfig();
    NSString *cur = cfg[@"plan_name"] ?: @"";
    id pv = cfg[@"pin_to_desktop"];
    BOOL pin = pv ? [pv boolValue] : YES;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *head = [[NSMenuItem alloc] initWithTitle:@"订阅套餐" action:nil keyEquivalent:@""];
    head.enabled = NO; [menu addItem:head];
    BOOL manual = [cfg[@"plan_manual"] boolValue];
    NSMenuItem *autoIt = [[NSMenuItem alloc] initWithTitle:@"自动检测"
                            action:@selector(planAuto:) keyEquivalent:@""];
    autoIt.target = self;
    autoIt.state = manual ? NSControlStateValueOff : NSControlStateValueOn;
    [menu addItem:autoIt];
    for (NSString *p in @[@"免费", @"Pro", @"Max 5x", @"Max 20x", @"Team"]) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:p
                            action:@selector(pickPlan:) keyEquivalent:@""];
        it.target = self;
        it.state = (manual && [p isEqualToString:cur]) ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:it];
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *pinIt = [[NSMenuItem alloc] initWithTitle:@"钉在桌面（窗口下层）"
                            action:@selector(togglePin:) keyEquivalent:@""];
    pinIt.target = self;
    pinIt.state = pin ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:pinIt];
    NSMenuItem *hideIt = [[NSMenuItem alloc] initWithTitle:@"隐藏桌面组件（菜单栏可找回）"
                            action:@selector(toggleWidgetHidden:) keyEquivalent:@""];
    hideIt.target = self; [menu addItem:hideIt];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *rf = [[NSMenuItem alloc] initWithTitle:@"立即刷新"
                            action:@selector(refreshNow:) keyEquivalent:@""];
    rf.target = self; [menu addItem:rf];
    NSMenuItem *q = [[NSMenuItem alloc] initWithTitle:@"退出"
                            action:@selector(quit:) keyEquivalent:@""];
    q.target = self; [menu addItem:q];

    [NSMenu popUpContextMenu:menu withEvent:e forView:self.view];
}
- (void)planAuto:(NSMenuItem *)it {
    NSMutableDictionary *cfg = LoadConfig();
    cfg[@"plan_manual"] = @NO;
    SaveConfig(cfg);
    self.lastProfileFetch = nil;  // re-detect soon
    [self presentFreshest];
}
- (void)pickPlan:(NSMenuItem *)it {
    NSMutableDictionary *cfg = LoadConfig();
    cfg[@"plan_name"] = it.title;
    cfg[@"plan_manual"] = @YES;
    SaveConfig(cfg);
    [self presentFreshest];
}
- (void)togglePin:(NSMenuItem *)it {
    NSMutableDictionary *cfg = LoadConfig();
    id pv = cfg[@"pin_to_desktop"];
    cfg[@"pin_to_desktop"] = @(pv ? ![pv boolValue] : NO);
    SaveConfig(cfg);
    [self applyWindowLevel];
}
- (void)refreshNow:(id)s { [self pollData]; }
- (void)quit:(id)s { [NSApp terminate:nil]; }
@end

// ─── Headless render for testing: ./ClaudeUsage --render out.png ──
static int RenderToPNG(NSString *path) {
    UsageData *d = LoadUsageFromCacheFile();
    NSMutableDictionary *cfg = LoadConfig();
    d.planName = [cfg[@"plan_name"] isKindOfClass:NSString.class] ? cfg[@"plan_name"] : @"—";
    CGFloat h = WidgetHeight(d.extras.count);
    WidgetView *v = [[WidgetView alloc] initWithFrame:NSMakeRect(0, 0, WIN_W, h)];
    v.data = d;
    CGFloat scale = 2;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(WIN_W*scale) pixelsHigh:(NSInteger)(h*scale)
                   bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = NSMakeSize(WIN_W, h);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [v drawRect:v.bounds];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:path atomically:YES];
    fprintf(stderr, "rendered %s | plan=%s 5h=%.0f 7d=%.0f extras=%lu real=%d\n",
            path.UTF8String, d.planName.UTF8String,
            d.fiveHour ? d.fiveHour.usedPct : -1,
            d.sevenDay ? d.sevenDay.usedPct : -1,
            (unsigned long)d.extras.count, d.hasReal);
    return 0;
}

// Render the menu panel in BOTH appearances (light on top, dark below) to
// verify it blends + adapts. ./ClaudeUsage --render-menu out.png
static int RenderMenuToPNG(NSString *path) {
    UsageData *d = LoadUsageFromCacheFile();
    NSMutableDictionary *cfg = LoadConfig();
    NSString *det = cfg[@"detected_plan"], *man = cfg[@"plan_name"];
    d.planName = [man isKindOfClass:NSString.class] ? man : (det ?: @"—");
    CGFloat h = MenuCardHeight(d.extras.count);
    NSArray<NSAppearanceName> *modes = @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua];
    NSColor *bgs[2] = { [NSColor colorWithWhite:0.96 alpha:1], [NSColor colorWithWhite:0.17 alpha:1] };

    // Render each appearance via cacheDisplayInRect (respects isFlipped + appearance).
    NSImage *imgs[2];
    for (int i = 0; i < 2; i++) {
        MenuCardView *v = [[MenuCardView alloc] initWithFrame:NSMakeRect(0, 0, MC_W, h)];
        v.appearance = [NSAppearance appearanceNamed:modes[i]];
        v.data = d;
        NSBitmapImageRep *vr = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
        [v cacheDisplayInRect:v.bounds toBitmapImageRep:vr];
        imgs[i] = [[NSImage alloc] initWithSize:NSMakeSize(MC_W, h)];
        [imgs[i] addRepresentation:vr];
    }

    NSImage *out = [[NSImage alloc] initWithSize:NSMakeSize(MC_W, h*2)];
    [out lockFocus];
    // light row on top (y=h..2h), dark row below (y=0..h)
    [bgs[0] setFill]; NSRectFill(NSMakeRect(0, h, MC_W, h));
    [bgs[1] setFill]; NSRectFill(NSMakeRect(0, 0, MC_W, h));
    [imgs[0] drawInRect:NSMakeRect(0, h, MC_W, h)];
    [imgs[1] drawInRect:NSMakeRect(0, 0, MC_W, h)];
    [out unlockFocus];

    NSBitmapImageRep *final = [NSBitmapImageRep imageRepWithData:[out TIFFRepresentation]];
    [[final representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    fprintf(stderr, "rendered menu %s (top=light, bottom=dark)\n", path.UTF8String);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--render") == 0)
                return RenderToPNG((i+1 < argc) ? @(argv[i+1]) : @"/tmp/widget.png");
            if (strcmp(argv[i], "--render-menu") == 0)
                return RenderMenuToPNG((i+1 < argc) ? @(argv[i+1]) : @"/tmp/menu.png");
        }
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AppDelegate *del = [AppDelegate new];
        app.delegate = del;
        [app run];
    }
    return 0;
}
