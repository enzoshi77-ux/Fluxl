// NullsBotFill.m
// Target : Null's Brawl client, arm64, iOS 14+
// Build  : ./build.sh    (clang + ld64.lld, no Apple SDK on the build host)
//          make          (Theos, macOS)
// Load   : LiveContainer app bundle -> Tweaks/NullsBotFill.dylib
//
// What it does
//   - fills a match with 5 fixed passive bots, local player untouched
//   - bots pick a random heading every WalkInterval seconds and only walk
//   - ranked: bots get a fixed brawler each, ban requests are swallowed so the
//     server-side auto-ban timer resolves it
//   - Solo Showdown / Bounty are skipped
//   - the join packet carries a per-device private room token and maxPlayers=1
//
// Every game class is resolved at load time. Nothing assumes a name that has
// not been observed on the running build: a missing target is logged and
// skipped, never crashed on.
// ---------------------------------------------------------------------------

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// Declared here instead of <execinfo.h> so the SDK-less build does not need
// another stub. Both symbols live in libsystem on iOS.
extern int backtrace(void **buffer, int size);
extern void backtrace_symbols_fd(void *const *buffer, int size, int fd);

static NSString *const kConfigFileName = @"NullsBotFill.plist";

#define NBF_PATH_MAX 1024

static char gLogPath[NBF_PATH_MAX];
static char gCrashReportPath[NBF_PATH_MAX];
static char gMarkerPath[NBF_PATH_MAX];
static char gCandidatePath[NBF_PATH_MAX];

static FILE *gLogFile = NULL;
static FILE *gCrashFile = NULL;
static int   gCrashFD = -1;

// 0 constructor running, 1 entry timer fired, 2 install pass done.
static volatile int gBootStage = 0;
static volatile sig_atomic_t gInCrashHandler = 0;

// Set when the previous run did not get through startup.
static int   gPreviousRunKind = 0;    // 0 clean, 1 crash report, 2 unclean start
static char *gPreviousRunText = NULL; // malloc'd, truncated for the alert

static void NBFWriteAll(int fd, const char *text) {
    if (fd < 0 || !text) return;
    size_t left = strlen(text);
    while (left > 0) {
        ssize_t written = write(fd, text, left);
        if (written <= 0) break;
        text += written;
        left -= (size_t)written;
    }
}

static int NBFFlushFile(FILE *fp) {
    if (!fp) return -1;
    fflush(fp);
    int fd = fileno(fp);
    if (fd >= 0) fsync(fd);
    return fd;
}

static char *NBFReadFile(const char *path, long maxBytes, BOOL tail) {
    if (!path || !path[0]) return NULL;
    FILE *fp = fopen(path, "rb");
    if (!fp) return NULL;

    long size = 0;
    if (fseek(fp, 0, SEEK_END) == 0) size = ftell(fp);
    if (size < 0) size = 0;

    long start = 0;
    if (tail && size > maxBytes) start = size - maxBytes;
    if (size - start > maxBytes) size = start + maxBytes;

    if (fseek(fp, start, SEEK_SET) != 0) { fclose(fp); return NULL; }

    long length = size - start;
    char *buffer = (char *)malloc((size_t)length + 1);
    if (!buffer) { fclose(fp); return NULL; }

    size_t got = fread(buffer, 1, (size_t)length, fp);
    fclose(fp);
    buffer[got] = '\0';
    return buffer;
}

static BOOL NBFDirectoryUsable(const char *dir) {
    if (!dir || !dir[0]) return NO;
    mkdir(dir, 0755);

    char probe[NBF_PATH_MAX];
    snprintf(probe, sizeof(probe), "%s/.nbf-probe", dir);
    FILE *fp = fopen(probe, "a");
    if (!fp) return NO;
    fclose(fp);
    unlink(probe);
    return YES;
}

// Pure C on purpose: this runs from the constructor, possibly before
// Foundation's own initialisers, and a crash logger must not depend on that.
// Documents first (survives, visible in Files), tmp second.
static void NBFSetupPaths(void) {
    char documents[NBF_PATH_MAX];
    documents[0] = '\0';

    const char *home = getenv("HOME");
    if (home && home[0]) {
        snprintf(documents, sizeof(documents), "%s/Documents/NullsBotFill", home);
    }

    const char *tempdir = getenv("TMPDIR");
    char candidate[NBF_PATH_MAX];
    const char *chosen = NULL;

    if (documents[0] && NBFDirectoryUsable(documents)) {
        chosen = documents;
    } else if (tempdir && tempdir[0]) {
        snprintf(candidate, sizeof(candidate), "%s/NullsBotFill", tempdir);
        if (NBFDirectoryUsable(candidate)) chosen = candidate;
    }
    if (!chosen && NBFDirectoryUsable("/tmp/NullsBotFill")) {
        chosen = "/tmp/NullsBotFill";
    }
    if (!chosen) return;

    snprintf(gLogPath, sizeof(gLogPath), "%s/NullsBotFill.log", chosen);
    snprintf(gCrashReportPath, sizeof(gCrashReportPath),
             "%s/NullsBotFill-crash.txt", chosen);
    snprintf(gMarkerPath, sizeof(gMarkerPath), "%s/NullsBotFill.session", chosen);
    snprintf(gCandidatePath, sizeof(gCandidatePath),
             "%s/NullsBotFill-candidates.txt", chosen);

    gLogFile = fopen(gLogPath, "a");
    if (gLogFile) NBFFlushFile(gLogFile);

    gCrashFile = fopen(gCrashReportPath, "a");
    if (gCrashFile) gCrashFD = fileno(gCrashFile);
}

// The shown report is deleted so it does not pop up again. Reopen the file so a
// crash later in this same launch is still recorded.
static void NBFReopenCrashFile(void) {
    if (gCrashFile) fclose(gCrashFile);
    gCrashFile = NULL;
    gCrashFD = -1;
    if (!gCrashReportPath[0]) return;
    gCrashFile = fopen(gCrashReportPath, "a");
    if (gCrashFile) gCrashFD = fileno(gCrashFile);
}


static const char *NBFSignalName(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV (bad memory access)";
        case SIGABRT: return "SIGABRT (abort / uncaught exception)";
        case SIGBUS:  return "SIGBUS (bad address)";
        case SIGILL:  return "SIGILL (illegal instruction)";
        case SIGFPE:  return "SIGFPE (arithmetic)";
        case SIGTRAP: return "SIGTRAP (trap)";
        case SIGTERM: return "SIGTERM";
        default:      return "unknown signal";
    }
}

// Async-signal-safe: only write(2), fsync(2), backtrace and raise.
static void NBFCrashHandler(int sig) {
    if (gInCrashHandler) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    gInCrashHandler = 1;

    int fd = gCrashFD >= 0 ? gCrashFD : 2;
    char header[512];
    int n = snprintf(header, sizeof(header),
                     "\n===== NullsBotFill crash =====\n"
                     "signal : %d %s\n"
                     "stage  : %d (0=constructor 1=entry 2=hooks installed)\n"
                     "pid    : %d\n"
                     "epoch  : %ld\n"
                     "note   : the last line of NullsBotFill.log is the last\n"
                     "         thing that ran before this signal.\n"
                     "backtrace:\n",
                     sig, NBFSignalName(sig), (int)gBootStage,
                     (int)getpid(), (long)time(NULL));
    if (n > 0) NBFWriteAll(fd, header);

    void *frames[128];
    int count = backtrace(frames, (int)(sizeof(frames) / sizeof(frames[0])));
    if (count > 0) backtrace_symbols_fd(frames, count, fd);
    fsync(fd);

    // Let the system's own crash reporter run as well.
    signal(sig, SIG_DFL);
    raise(sig);
}

static void NBFExceptionHandler(NSException *exception) {
    if (gInCrashHandler) return;
    gInCrashHandler = 1;

    int fd = gCrashFD >= 0 ? gCrashFD : 2;
    const char *name = [[exception name] UTF8String];
    const char *reason = [[exception reason] UTF8String];
    char header[512];
    snprintf(header, sizeof(header),
             "\n===== NullsBotFill uncaught exception =====\n"
             "name   : %s\n"
             "reason : %s\n"
             "stage  : %d\n"
             "pid    : %d\n"
             "epoch  : %ld\n"
             "backtrace:\n",
             name ? name : "?",
             reason ? reason : "?",
             (int)gBootStage, (int)getpid(), (long)time(NULL));
    NBFWriteAll(fd, header);

    void *frames[128];
    int count = backtrace(frames, (int)(sizeof(frames) / sizeof(frames[0])));
    if (count > 0) backtrace_symbols_fd(frames, count, fd);
    fsync(fd);
}

static const int kCrashSignals[] = {
    SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP
};

// Pure C, safe from the constructor.
static void NBFInstallSignalHandlers(void) {
    for (size_t i = 0; i < sizeof(kCrashSignals) / sizeof(kCrashSignals[0]); i++) {
        signal(kCrashSignals[i], NBFCrashHandler);
    }
}

// Foundation is guaranteed live by the time the entry timer fires.
static void NBFInstallExceptionHandler(void) {
    NSSetUncaughtExceptionHandler(NBFExceptionHandler);
}

static void NBFWriteMarker(const char *stage) {
    if (!gMarkerPath[0]) return;
    FILE *fp = fopen(gMarkerPath, "w");
    if (!fp) return;
    char line[256];
    snprintf(line, sizeof(line), "stage=%s pid=%d stage_id=%d\n",
             stage, (int)getpid(), (int)gBootStage);
    fputs(line, fp);
    NBFFlushFile(fp);
    fclose(fp);
}

static void NBFLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *message = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSLog(@"[NBF] %@", message);
    if (!gLogFile) return;

    const char *text = [message UTF8String];
    if (!text) text = "(unprintable message)";

    char stamp[40];
    time_t now = time(NULL);
    char readable[40];
    char *asctime = ctime_r(&now, readable);
    if (asctime) {
        snprintf(stamp, sizeof(stamp), "%s", asctime);
        for (char *p = stamp; *p; p++) {
            if (*p == '\n') { *p = '\0'; break; }
        }
    } else {
        snprintf(stamp, sizeof(stamp), "%ld", (long)now);
    }

    char line[4096];
    snprintf(line, sizeof(line), "[%s] %s\n", stamp, text);
    NBFWriteAll(fileno(gLogFile), line);
    NBFFlushFile(gLogFile);
}


// Called before the first log line of this run, so the previous marker and the
// previous log tail are still intact.
static void NBFCheckPreviousRun(void) {
    char *report = NBFReadFile(gCrashReportPath, 256 * 1024, NO);
    if (report && report[0]) {
        gPreviousRunKind = 1;
        if (strlen(report) > 1800) report[1800] = '\0';
        gPreviousRunText = report;
        return;
    }
    free(report);

    char *marker = NBFReadFile(gMarkerPath, 256, NO);
    if (!marker) return;
    BOOL finished = (strncmp(marker, "stage=ready", 11) == 0);
    free(marker);
    if (finished) return;

    gPreviousRunKind = 2;
    char *tail = NBFReadFile(gLogPath, 8000, YES);
    if (tail) {
        size_t len = strlen(tail);
        if (len > 1800) {
            // Keep the end: that is where the process died.
            memmove(tail, tail + (len - 1800), 1801);
        }
    }
    gPreviousRunText = tail;
}

// Surfaces the previous crash. Retries because the root view controller does
// not exist yet on a cold launch.
static void NBFPresentCrashAlert(int attempt) {
    if (!gPreviousRunText || !gPreviousRunText[0]) return;

    Class alertClass = NSClassFromString(@"UIAlertController");
    Class actionClass = NSClassFromString(@"UIAlertAction");
    Class pasteboardClass = NSClassFromString(@"UIPasteboard");
    UIApplication *app = [UIApplication sharedApplication];
    id root = nil;
    for (id window in [app windows]) {
        root = [window rootViewController];
        if (root) break;
    }

    if (!alertClass || !actionClass || !root) {
        if (attempt < 12) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NBFPresentCrashAlert(attempt + 1);
            });
        }
        return;
    }

    NSString *body = [NSString stringWithUTF8String:gPreviousRunText];
    if (!body) return;

    NSString *title = (gPreviousRunKind == 1)
        ? @"NullsBotFill: last launch crashed"
        : @"NullsBotFill: last launch ended early";
    NSString *message = [NSString stringWithFormat:
        @"Copied to the clipboard. Paste it back for a fix.\n\n%@", body];

    // Clear the shown report first: a crash while the alert is on screen must
    // still land in a fresh file.
    if (gPreviousRunKind == 1) {
        unlink(gCrashReportPath);
        NBFReopenCrashFile();
    }

    @try {
        if (pasteboardClass) {
            id pasteboard = [pasteboardClass generalPasteboard];
            if (pasteboard) [pasteboard setString:message];
        }

        id alert = [alertClass alertControllerWithTitle:title
                                               message:message
                                        preferredStyle:1];
        if (!alert) return;
        [alert addAction:[actionClass actionWithTitle:@"OK"
                                                style:0
                                              handler:nil]];
        [root presentViewController:alert animated:YES completion:nil];
    } @catch (id exception) {
        NBFLog(@"could not present crash alert: %@", exception);
    }
}

// Plain-C breadcrumb written from the constructor, before any Objective-C
// call. If the app dies before NullsBotFill.log exists, this file still shows
// whether dyld loaded the image.
static void NBFBootLog(const char *message) {
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) return;
    char path[1024];
    int written = snprintf(path, sizeof(path), "%s/NullsBotFill-boot.log", tmp);
    if (written <= 0 || (size_t)written >= sizeof(path)) return;
    FILE *fp = fopen(path, "a");
    if (!fp) return;
    fputs(message, fp);
    fputs("\n", fp);
    fclose(fp);
}

// ---------------------------------------------------------------------------
// KVC PROBING
// A key that throws does not exist on that object. Resolved once per class,
// never per frame: KVC exception unwinding is expensive.
// ---------------------------------------------------------------------------

static id NBFGetProp(id object, NSString *key) {
    @try {
        return [object valueForKey:key];
    } @catch (...) {
        return nil;
    }
}

static BOOL NBFSetProp(id object, NSString *key, id value) {
    @try {
        [object setValue:value forKey:key];
        return YES;
    } @catch (...) {
        return NO;
    }
}

static BOOL NBFHasKey(id object, NSString *key) {
    @try {
        [object valueForKey:key];
        return YES;
    } @catch (...) {
        return NO;
    }
}

static BOOL NBFSetFirst(id object, NSArray *keys, id value) {
    for (NSString *key in keys) {
        if (NBFSetProp(object, key, value)) return YES;
    }
    return NO;
}

// Associated object keys — address of a static byte is unique and stable.
static const char kBotPlayerKey = 0;
static const char kBotSlotKey   = 1;
static const char kBotEntityKey = 2;
static const char kBotStateKey  = 3;

// ---------------------------------------------------------------------------
// CONFIG
// ---------------------------------------------------------------------------

@interface NBFConfig : NSObject
@property (nonatomic, copy) NSArray *botBrawlerIds;
@property (nonatomic, copy) NSArray *rankedBrawlerIds;
@property (nonatomic, copy) NSArray *botNames;
@property (nonatomic, copy) NSArray *excludedModes;
@property (nonatomic, copy) NSArray *playerClasses;
@property (nonatomic, copy) NSArray *setupClasses;
@property (nonatomic, copy) NSArray *setupSelectors;
@property (nonatomic, copy) NSArray *tickClasses;
@property (nonatomic, copy) NSArray *tickSelectors;
@property (nonatomic, copy) NSArray *pickClasses;
@property (nonatomic, copy) NSArray *pickSelectorNames;
@property (nonatomic, copy) NSArray *banSelectorNames;
@property (nonatomic, copy) NSArray *joinClasses;
@property (nonatomic, copy) NSArray *joinSelectorNames;
@property (nonatomic, assign) int botBaseId;
@property (nonatomic, assign) float walkInterval;
@property (nonatomic, assign) BOOL rankedEnabled;
@property (nonatomic, assign) BOOL tickSuppressOriginal;
@property (nonatomic, assign) BOOL dumpCandidates;
@property (nonatomic, assign) BOOL scanUnlistedClasses;
@property (nonatomic, assign) BOOL dryRun;

+ (instancetype)shared;
- (int)brawlerIdForSlot:(int)slot ranked:(BOOL)ranked;
@end


static NSArray *NBFArrayOverride(NSDictionary *dict, NSString *key,
                                 NSArray *fallback, Class elementClass) {
    id value = [dict objectForKey:key];
    if (!value) return fallback;
    if (![value isKindOfClass:[NSArray class]]) {
        NBFLog(@"ignoring %@: not an array", key);
        return fallback;
    }
    if (elementClass) {
        for (id item in (NSArray *)value) {
            if (![item isKindOfClass:elementClass]) {
                NBFLog(@"ignoring %@: element %@ is not %@",
                       key, NSStringFromClass([item class]),
                       NSStringFromClass(elementClass));
                return fallback;
            }
        }
    }
    return (NSArray *)value;
}

@implementation NBFConfig

+ (instancetype)shared {
    static NBFConfig *config = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        config = [[NBFConfig alloc] init];
        [config loadOverrides];
    });
    return config;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    self.botBrawlerIds = @[ @0, @1, @2, @3, @4 ];
    self.rankedBrawlerIds = @[ @5, @6, @7, @8, @9 ];
    self.botNames = @[ @"BOT_01", @"BOT_02", @"BOT_03", @"BOT_04", @"BOT_05" ];
    self.excludedModes = @[ @"soloShowdown", @"bounty" ];
    self.playerClasses = @[ @"PlayerEntry", @"BattlePlayer", @"ClientPlayer",
                            @"Player", @"MatchPlayer" ];
    self.setupClasses = @[ @"BattleManager", @"ClientBattle", @"BattleSetupManager",
                           @"Battle", @"MatchManager" ];
    self.setupSelectors = @[ @"applyMatchConfig:", @"setupBattle:",
                             @"startBattle:", @"initBattle:" ];
    self.tickClasses = @[ @"BattleEntity", @"CharacterLogic", @"BrawlerEntity",
                          @"ClientCharacter", @"BattlePlayer" ];
    self.tickSelectors = @[ @"updateTick:", @"update:", @"tick:" ];
    self.pickClasses = @[ @"RankedPickManager", @"DraftManager", @"PickPhaseManager" ];
    self.pickSelectorNames = @[ @"requestBrawlerPickForPlayer:", @"handlePickTurn:" ];
    self.banSelectorNames = @[ @"requestBanForPlayer:", @"handleBanTurn:" ];
    self.joinClasses = @[ @"MatchmakingManager", @"LobbyManager",
                          @"JoinPacketBuilder", @"NetworkManager" ];
    self.joinSelectorNames = @[ @"buildJoinPacket:" ];

    self.botBaseId = 10000100;
    self.walkInterval = 1.5f;
    self.rankedEnabled = YES;
    self.tickSuppressOriginal = YES;
    self.dumpCandidates = YES;
    self.scanUnlistedClasses = NO;
    self.dryRun = NO;

    return self;
}

- (void)loadOverrides {
    NSMutableArray *candidates = [NSMutableArray array];
    NSString *tmp = NSTemporaryDirectory();
    if (tmp) [candidates addObject:[tmp stringByAppendingString:kConfigFileName]];

    const char *home = getenv("HOME");
    if (home) {
        NSString *h = [NSString stringWithUTF8String:home];
        [candidates addObject:[[h stringByAppendingString:@"/Documents/"]
                                  stringByAppendingString:kConfigFileName]];
    }

    for (NSString *path in candidates) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!dict) continue;

        id value = nil;
        self.botBrawlerIds = NBFArrayOverride(dict, @"BotBrawlerIds",
                                             self.botBrawlerIds, [NSNumber class]);
        self.rankedBrawlerIds = NBFArrayOverride(dict, @"RankedBrawlerIds",
                                                self.rankedBrawlerIds, [NSNumber class]);
        self.botNames = NBFArrayOverride(dict, @"BotNames", self.botNames, [NSString class]);
        self.excludedModes = NBFArrayOverride(dict, @"ExcludedModes",
                                             self.excludedModes, [NSString class]);
        self.playerClasses = NBFArrayOverride(dict, @"PlayerClasses",
                                             self.playerClasses, [NSString class]);
        self.setupClasses = NBFArrayOverride(dict, @"SetupClasses",
                                            self.setupClasses, [NSString class]);
        self.setupSelectors = NBFArrayOverride(dict, @"SetupSelectors",
                                              self.setupSelectors, [NSString class]);
        self.tickClasses = NBFArrayOverride(dict, @"TickClasses",
                                           self.tickClasses, [NSString class]);
        self.tickSelectors = NBFArrayOverride(dict, @"TickSelectors",
                                             self.tickSelectors, [NSString class]);
        self.pickClasses = NBFArrayOverride(dict, @"PickClasses",
                                           self.pickClasses, [NSString class]);
        self.pickSelectorNames = NBFArrayOverride(dict, @"PickSelectors",
                                                 self.pickSelectorNames, [NSString class]);
        self.banSelectorNames = NBFArrayOverride(dict, @"BanSelectors",
                                                self.banSelectorNames, [NSString class]);
        self.joinClasses = NBFArrayOverride(dict, @"JoinClasses",
                                           self.joinClasses, [NSString class]);
        self.joinSelectorNames = NBFArrayOverride(dict, @"JoinSelectors",
                                                 self.joinSelectorNames, [NSString class]);

        if ((value = [dict objectForKey:@"BotBaseId"]))        self.botBaseId = [value intValue];
        if ((value = [dict objectForKey:@"WalkInterval"])) {
            float interval = [value floatValue];
            if (interval > 0.0f && interval <= 3600.0f) self.walkInterval = interval;
            else NBFLog(@"ignoring WalkInterval: %@ is not a positive number", value);
        }
        if ((value = [dict objectForKey:@"RankedEnabled"]))    self.rankedEnabled = [value boolValue];
        if ((value = [dict objectForKey:@"TickSuppressOriginal"]))
            self.tickSuppressOriginal = [value boolValue];
        if ((value = [dict objectForKey:@"DumpCandidates"]))
            self.dumpCandidates = [value boolValue];
        if ((value = [dict objectForKey:@"ScanUnlistedClasses"]))
            self.scanUnlistedClasses = [value boolValue];
        if ((value = [dict objectForKey:@"DryRun"]))
            self.dryRun = [value boolValue];

        NBFLog(@"config loaded from %@", path);
        return;
    }

    NBFLog(@"no config plist found, using built-in defaults");
}

- (int)brawlerIdForSlot:(int)slot ranked:(BOOL)ranked {
    NSArray *source = ranked ? self.rankedBrawlerIds : self.botBrawlerIds;
    if (![source isKindOfClass:[NSArray class]] || [source count] == 0) return 0;
    if (slot < 0) slot = 0;
    if ((NSUInteger)slot >= [source count]) slot = (int)([source count] - 1);
    id value = [source objectAtIndex:(NSUInteger)slot];
    return [value respondsToSelector:@selector(intValue)] ? [value intValue] : 0;
}

@end


// ---------------------------------------------------------------------------
// HOOK INSTALL
// Swaps a game method with one of ours. The original stays reachable under our
// selector, so a handler can trampoline into it and keep the game's own work.
// ---------------------------------------------------------------------------

static NSMutableSet *gInstalled  = nil;  // "Class::selector" — no double swizzle
static NSMutableSet *gHookUse    = nil;  // "Class::hookSelector" — one target per hook
static int gHookCount = 0;

static BOOL NBFParseTickEncoding(const char *types, BOOL *usesDouble);

// Returns YES for exactly  void (id self, SEL _cmd, id argument).
// Type offsets and ObjC qualifiers are ignored; the caller already knows which
// selector it is installing and only needs the ABI shape to match.
static BOOL NBFEncodingTakesSingleObject(const char *types) {
    if (!types || types[0] != 'v') return NO;

    const char *p = types + 1;
    while (*p >= '0' && *p <= '9') p++;      // return-value offset
    if (*p++ != '@') return NO;              // self
    while (*p >= '0' && *p <= '9') p++;
    if (*p++ != ':') return NO;              // _cmd
    while (*p >= '0' && *p <= '9') p++;

    while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' ||
           *p == 'O' || *p == 'R' || *p == 'V') p++;
    if (*p++ != '@') return NO;              // argument

    if (*p == '"') {                         // @"ClassName"
        p++;
        while (*p && *p != '"') p++;
        if (*p == '"') p++;
    }
    while (*p >= '0' && *p <= '9') p++;      // argument offset
    return *p == '\0';
}

// A method exchanged into a superclass must never be exchanged a second time
// into a subclass: the subclass trampoline would call itself forever. This
// checks whether an ancestor already owns the hooked selector.
static BOOL NBFAncestorHooked(Class target, SEL gameSel) {
    NSString *selName = [NSString stringWithUTF8String:sel_getName(gameSel)];
    for (Class cls = class_getSuperclass(target); cls; cls = class_getSuperclass(cls)) {
        NSString *tag = [NSString stringWithFormat:@"%s::%@",
                         class_getName(cls), selName];
        if ([gInstalled containsObject:tag]) return YES;
    }
    return NO;
}

static BOOL NBFInstallMethod(Class target, SEL gameSel, Class hookClass, SEL hookSel) {
    if (!target || !gameSel || !hookClass || !hookSel) return NO;

    if (!gInstalled) gInstalled = [NSMutableSet set];
    if (!gHookUse) gHookUse = [NSMutableSet set];

    NSString *tag = [NSString stringWithFormat:@"%s::%s",
                     class_getName(target), sel_getName(gameSel)];
    if ([gInstalled containsObject:tag]) return NO;

    // A second install on the same class through the same hook selector would
    // exchange two *different* originals into the same slot. Refuse it: one
    // class, one trampoline per hook.
    NSString *useTag = [NSString stringWithFormat:@"%s::%s",
                        class_getName(target), sel_getName(hookSel)];
    if ([gHookUse containsObject:useTag]) return NO;

    Method game = class_getInstanceMethod(target, gameSel);
    Method hook = class_getInstanceMethod(hookClass, hookSel);
    if (!game || !hook) {
        NBFLog(@"skip -[%s %s]: method missing",
               class_getName(target), sel_getName(gameSel));
        return NO;
    }

    const char *gameTypes = method_getTypeEncoding(game);
    if (hookSel == @selector(nbf_tickF:) || hookSel == @selector(nbf_tickD:)) {
        BOOL usesDouble = NO;
        BOOL isTick = NBFParseTickEncoding(gameTypes, &usesDouble);
        BOOL wantsDouble = (hookSel == @selector(nbf_tickD:));
        if (!isTick || usesDouble != wantsDouble) {
            NBFLog(@"skip -[%s %s]: tick encoding %s does not match trampoline",
                   class_getName(target), sel_getName(gameSel), gameTypes);
            return NO;
        }
    } else if (!NBFEncodingTakesSingleObject(gameTypes)) {
        // Calling a method that takes an int, no argument, or two arguments
        // through a (id) trampoline is an ABI fault, not a catchable exception.
        NBFLog(@"skip -[%s %s]: encoding %s is not (id)",
               class_getName(target), sel_getName(gameSel), gameTypes);
        return NO;
    }

    Class super = class_getSuperclass(target);
    BOOL inherited = (super != Nil && class_getInstanceMethod(super, gameSel) == game);

    // The superclass hook already covers instances of this class. Only install
    // here when this class defines its own override.
    if (inherited && NBFAncestorHooked(target, gameSel)) {
        NBFLog(@"skip -[%s %s]: covered by a superclass hook",
               class_getName(target), sel_getName(gameSel));
        return NO;
    }

    // Give the target its own copy of the game method. Without this, an
    // inherited method would be exchanged in the superclass and a later hook
    // on a sibling class would trampoline into itself.
    if (inherited) {
        if (!class_addMethod(target, gameSel,
                             method_getImplementation(game),
                             gameTypes)) {
            NBFLog(@"skip -[%s %s]: could not materialise own method",
                   class_getName(target), sel_getName(gameSel));
            return NO;
        }
        game = class_getInstanceMethod(target, gameSel);
        if (!game) return NO;
    }

    // The trampoline selector must be new on this class. class_getInstanceMethod
    // also finds inherited methods, so any hit means it is not ours to add.
    if (class_getInstanceMethod(target, hookSel) != NULL) {
        NBFLog(@"skip -[%s %s]: trampoline selector already exists",
               class_getName(target), sel_getName(gameSel));
        return NO;
    }

    if (!class_addMethod(target, hookSel,
                         method_getImplementation(hook),
                         method_getTypeEncoding(hook))) {
        NBFLog(@"skip -[%s %s]: trampoline could not be added",
               class_getName(target), sel_getName(gameSel));
        return NO;
    }

    Method installed = class_getInstanceMethod(target, hookSel);
    if (!installed ||
        method_getImplementation(installed) != method_getImplementation(hook)) {
        NBFLog(@"skip -[%s %s]: hook implementation did not land",
               class_getName(target), sel_getName(gameSel));
        return NO;
    }

    method_exchangeImplementations(game, installed);

    [gInstalled addObject:tag];
    [gHookUse addObject:useTag];
    gHookCount++;
    NBFLog(@"hooked -[%s %s]", class_getName(target), sel_getName(gameSel));
    return YES;
}

// All non-meta classes currently registered with the runtime.
static Class *NBFCopyClasses(unsigned int *outCount) {
    return objc_copyClassList(outCount);
}

// Class-name tokens that make a class a plausible hook target. Keeps the scan
// away from UIKit internals that happen to expose a tick:.
static BOOL NBFNameLooksLikeGameClass(const char *name) {
    static const char *tokens[] = {
        "Battle", "Player", "Match", "Lobby", "Room", "Rank", "Pick",
        "Ban", "Bot", "Game", "Arena", "Logic", "Entity", "Character"
    };
    if (!name) return NO;
    for (size_t i = 0; i < sizeof(tokens) / sizeof(tokens[0]); i++) {
        if (strstr(name, tokens[i])) return YES;
    }
    return NO;
}

// Strict variant for install scans: only battle-side classes, so a UIKit class
// whose name happens to contain "Player" is never touched.
static BOOL NBFNameLooksLikeBattleClass(const char *name) {
    static const char *tokens[] = {
        "Battle", "Brawl", "Arena", "Lobby", "Matchmaking", "Ranked",
        "Logic", "Combat", "GameServer"
    };
    if (!name) return NO;
    for (size_t i = 0; i < sizeof(tokens) / sizeof(tokens[0]); i++) {
        if (strstr(name, tokens[i])) return YES;
    }
    return NO;
}

// v<off>@:<off>f<off>  or  v<off>@:<off>d<off>  — exactly one scalar argument.
static BOOL NBFParseTickEncoding(const char *types, BOOL *usesDouble) {
    if (!types || types[0] != 'v') return NO;
    const char *p = types + 1;
    while (*p >= '0' && *p <= '9') p++;
    if (*p++ != '@') return NO;
    while (*p >= '0' && *p <= '9') p++;
    if (*p++ != ':') return NO;
    while (*p >= '0' && *p <= '9') p++;
    if (*p == 'f') { if (usesDouble) *usesDouble = NO;  return YES; }
    if (*p == 'd') { if (usesDouble) *usesDouble = YES; return YES; }
    return NO;
}


// ---------------------------------------------------------------------------
// BOT IDENTITY
// Player entries and battle entities are different objects. A bot is matched by
// its synthetic id range or its fixed name, then the answer is cached on the
// object: one KVC pass per entity, never per frame.
// ---------------------------------------------------------------------------

static BOOL NBFIsBotPlayer(id object) {
    if (!object) return NO;
    if ([objc_getAssociatedObject(object, &kBotPlayerKey) boolValue]) return YES;

    NBFConfig *cfg = [NBFConfig shared];
    id pid = NBFGetProp(object, @"playerId") ?: NBFGetProp(object, @"playerID");
    if ([pid respondsToSelector:@selector(longLongValue)]) {
        long long value = [pid longLongValue];
        if (value >= cfg.botBaseId && value < (long long)cfg.botBaseId + 16) return YES;
    }

    NSString *name = NBFGetProp(object, @"name");
    if ([name isKindOfClass:[NSString class]] &&
        [cfg.botNames isKindOfClass:[NSArray class]]) {
        for (NSString *botName in cfg.botNames) {
            if ([name isEqualToString:botName]) return YES;
        }
    }
    return NO;
}

// The slot decides the brawler. Prefer the value stamped at creation, then a
// property, then the synthetic player id. Never let a negative slot wrap into
// objectAtIndex:.
static int NBFSlotForPlayer(id player) {
    NBFConfig *cfg = [NBFConfig shared];
    int slot = -1;

    NSNumber *stamped = objc_getAssociatedObject(player, &kBotSlotKey);
    if ([stamped isKindOfClass:[NSNumber class]]) slot = [stamped intValue];

    if (slot < 0) {
        id value = NBFGetProp(player, @"botSlot");
        if ([value respondsToSelector:@selector(intValue)]) slot = [value intValue];
    }

    if (slot < 0) {
        id pid = NBFGetProp(player, @"playerId") ?: NBFGetProp(player, @"playerID");
        if ([pid respondsToSelector:@selector(longLongValue)]) {
            long long value = [pid longLongValue] - cfg.botBaseId;
            if (value >= 0 && value < 16) slot = (int)value;
        }
    }

    if (slot < 0) slot = 0;
    if (slot > 4) slot = 4;
    return slot;
}

static BOOL NBFIsBotEntity(id entity) {
    if (!entity) return NO;
    NSNumber *cached = objc_getAssociatedObject(entity, &kBotEntityKey);
    if (cached) return [cached boolValue];

    BOOL isBot = NBFIsBotPlayer(entity);
    objc_setAssociatedObject(entity, &kBotEntityKey,
                             isBot ? @YES : @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return isBot;
}

// ---------------------------------------------------------------------------
// MOVEMENT KEYS
// Resolved once for the whole bot class. Each candidate pair is probed with a
// real KVC read; the first pair that exists wins and is cached, so the tick
// loop does no exception work.
// ---------------------------------------------------------------------------

static Class    gMoveKeysClass   = Nil;
static NSArray *gMoveKeys        = nil;
static Class    gAttackKeysClass = Nil;
static NSArray *gAttackKeys      = nil;

static NSArray *NBFResolveMoveKeys(id entity) {
    Class cls = [entity class];
    if (cls == gMoveKeysClass) return gMoveKeys;

    NSArray *pairs = @[ @[ @"moveX", @"moveY" ],
                        @[ @"inputX", @"inputY" ],
                        @[ @"movementX", @"movementY" ],
                        @[ @"joystickX", @"joystickY" ],
                        @[ @"directionX", @"directionY" ] ];

    NSArray *found = nil;
    for (NSArray *pair in pairs) {
        if (NBFHasKey(entity, [pair objectAtIndex:0]) &&
            NBFHasKey(entity, [pair objectAtIndex:1])) {
            found = pair;
            break;
        }
    }

    if (found) {
        NBFLog(@"movement keys on %s: %@/%@", class_getName(cls),
               [found objectAtIndex:0], [found objectAtIndex:1]);
    } else {
        NBFLog(@"no movement keys on %s — heading is set but the body may not move",
               class_getName(cls));
    }

    gMoveKeysClass = cls;
    gMoveKeys = found;
    return found;
}

static NSArray *NBFResolveAttackKeys(id entity) {
    Class cls = [entity class];
    if (cls == gAttackKeysClass) return gAttackKeys;

    NSArray *candidates = @[ @"wantsToAttack", @"attackPressed", @"isAttacking",
                             @"attackHeld", @"shootHeld", @"autoAttack",
                             @"wantsToUseSuper", @"useSuper", @"superPressed" ];
    NSMutableArray *present = [NSMutableArray array];
    for (NSString *key in candidates) {
        if (NBFHasKey(entity, key)) [present addObject:key];
    }

    gAttackKeysClass = cls;
    gAttackKeys = present;
    return present;
}


// ---------------------------------------------------------------------------
// BOT STATE + FACTORY
// ---------------------------------------------------------------------------

@interface NBFBotState : NSObject
@property (nonatomic, assign) float timer;
@property (nonatomic, assign) float angle;
@end

@implementation NBFBotState
@end

static Class gPlayerClass = Nil;
static BOOL  gPlayerClassResolved = NO;

// Crash-free existence test: never instantiates the candidate. An inherited
// KVC key or a playerId setter is enough to accept the class; alloc/init is
// deferred to the moment a bot is actually built inside a live match.
static BOOL NBFClassExposesPlayerId(Class cls) {
    unsigned int count = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        const char *name = property_getName(properties[i]);
        if (name && strcmp(name, "playerId") == 0) { found = YES; break; }
    }
    if (properties) free(properties);
    if (found) return YES;

    return class_getInstanceMethod(cls, sel_registerName("setPlayerId:")) != NULL;
}

static Class NBFResolvePlayerClass(void) {
    if (gPlayerClassResolved) return gPlayerClass;
    gPlayerClassResolved = YES;

    NBFConfig *cfg = [NBFConfig shared];

    for (NSString *name in cfg.playerClasses) {
        Class cls = NSClassFromString(name);
        if (cls && NBFClassExposesPlayerId(cls)) {
            gPlayerClass = cls;
            NBFLog(@"player class: %@", name);
            return cls;
        }
    }

    if (cfg.scanUnlistedClasses) {
        unsigned int count = 0;
        Class *classes = NBFCopyClasses(&count);
        if (classes) {
            for (unsigned int i = 0; i < count && !gPlayerClass; i++) {
                const char *name = class_getName(classes[i]);
                if (!NBFNameLooksLikeGameClass(name)) continue;
                if (!strstr(name, "Player")) continue;
                if (NBFClassExposesPlayerId(classes[i])) {
                    gPlayerClass = classes[i];
                    NBFLog(@"player class (scanned): %s", name);
                }
            }
            free(classes);
        }
    }

    if (!gPlayerClass) {
        NBFLog(@"no player class found — bot injection disabled on this build");
    }
    return gPlayerClass;
}

static id NBFCreateBot(int slot, BOOL ranked) {
    Class cls = NBFResolvePlayerClass();
    if (!cls) return nil;

    NBFConfig *cfg = [NBFConfig shared];
    if (slot < 0 || slot > 4) return nil;
    if (![cfg.botNames isKindOfClass:[NSArray class]] ||
        (NSUInteger)slot >= [cfg.botNames count]) return nil;
    id name = [cfg.botNames objectAtIndex:(NSUInteger)slot];
    if (![name isKindOfClass:[NSString class]]) return nil;

    // Allocating an unknown game class is still the riskiest operation here:
    // an -init that touches uninitialised C++ members faults below @try. The
    // class is only used after the property probe in NBFResolvePlayerClass.
    id bot = nil;
    @try {
        bot = [[cls alloc] init];
    } @catch (id exception) {
        NBFLog(@"bot alloc for %s threw: %@", class_getName(cls), exception);
        return nil;
    }
    if (!bot || ![bot isKindOfClass:cls]) return nil;

    NSNumber *brawlerId = @([cfg brawlerIdForSlot:slot ranked:ranked]);
    NSNumber *playerId  = @(cfg.botBaseId + slot);

    // If the identity cannot be written the entity will look human to every
    // later hook. Do not inject it at all.
    if (!NBFSetFirst(bot, @[ @"playerId", @"playerID" ], playerId)) {
        NBFLog(@"bot class %s exposes no player id setter, injection skipped",
               class_getName(cls));
        return nil;
    }
    NBFSetProp(bot, @"name", name);
    NBFSetProp(bot, @"brawlerId", brawlerId);

    // OFFLINE_BOT_BRAWLER path: the client resolves the bot's own logic from
    // these flags instead of going to the matchmaking service.
    NBFSetFirst(bot, @[ @"isOfflineBot", @"offlineBot", @"isBot" ], @YES);
    NBFSetProp(bot, @"botSlot", @(slot));

    objc_setAssociatedObject(bot, &kBotPlayerKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(bot, &kBotSlotKey, @(slot),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return bot;
}

// ---------------------------------------------------------------------------
// BOT STEP
// Drives one bot for one frame. Attack intents are always cleared; the game's
// own tick is kept or dropped depending on TickSuppressOriginal.
// ---------------------------------------------------------------------------

static void NBFStepBot(id entity, double delta) {
    NBFConfig *cfg = [NBFConfig shared];

    NBFBotState *state = objc_getAssociatedObject(entity, &kBotStateKey);
    if (!state) {
        state = [[NBFBotState alloc] init];
        state.angle = ((float)(arc4random_uniform(360)) * (float)M_PI) / 180.0f;
        objc_setAssociatedObject(entity, &kBotStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    state.timer += (float)delta;
    if (state.timer >= cfg.walkInterval) {
        state.timer = 0.0f;
        state.angle = ((float)(arc4random_uniform(360)) * (float)M_PI) / 180.0f;
    }

    NSArray *moveKeys = NBFResolveMoveKeys(entity);
    if (moveKeys) {
        float x = cosf(state.angle);
        float y = sinf(state.angle);
        NBFSetProp(entity, [moveKeys objectAtIndex:0], @(x));
        NBFSetProp(entity, [moveKeys objectAtIndex:1], @(y));
    }

    NSArray *attackKeys = NBFResolveAttackKeys(entity);
    for (NSString *key in attackKeys) {
        NBFSetProp(entity, key, @NO);
    }
}

// ---------------------------------------------------------------------------
// ENTITY TICK HOOK
// Two variants because the game may tick with float or double. The encoding is
// checked before install, so a mismatch is skipped rather than a crash.
// ---------------------------------------------------------------------------

@interface NBFEntityHook : NSObject
- (void)nbf_tickF:(float)delta;
- (void)nbf_tickD:(double)delta;
@end

@implementation NBFEntityHook

- (void)nbf_tickF:(float)delta {
    if (!NBFIsBotEntity(self)) {
        [self nbf_tickF:delta];
        return;
    }
    NBFStepBot(self, (double)delta);
    if (![NBFConfig shared].tickSuppressOriginal) {
        [self nbf_tickF:delta];
    }
}

- (void)nbf_tickD:(double)delta {
    if (!NBFIsBotEntity(self)) {
        [self nbf_tickD:delta];
        return;
    }
    NBFStepBot(self, delta);
    if (![NBFConfig shared].tickSuppressOriginal) {
        [self nbf_tickD:delta];
    }
}

@end


// ---------------------------------------------------------------------------
// MATCH SETUP HOOK
// Runs after the shell has built its own roster, then replaces the roster with
// the local player plus 5 synthetic bots.
// ---------------------------------------------------------------------------

@interface NBFSetupHook : NSObject
- (void)nbf_applyMatchConfig:(id)config;
@end

@implementation NBFSetupHook

- (void)nbf_applyMatchConfig:(id)config {
    [self nbf_applyMatchConfig:config];   // original first: your slot populates

    NBFConfig *cfg = [NBFConfig shared];

    NSString *mode = NBFGetProp(self, @"gameMode");
    if (![mode isKindOfClass:[NSString class]]) mode = NBFGetProp(config, @"gameMode");
    if (![mode isKindOfClass:[NSString class]]) mode = NBFGetProp(config, @"mode");
    if (![mode isKindOfClass:[NSString class]]) mode = @"";

    for (NSString *excluded in cfg.excludedModes) {
        if ([mode localizedCaseInsensitiveCompare:excluded] == NSOrderedSame) {
            NBFLog(@"mode %@ excluded, roster untouched", mode);
            return;
        }
    }

    BOOL ranked = [mode localizedCaseInsensitiveContainsString:@"ranked"];
    if (ranked && !cfg.rankedEnabled) {
        NBFLog(@"ranked disabled in config, roster untouched");
        return;
    }

    NSArray *rosterKeys = @[ @"players", @"playerList", @"battlePlayers" ];
    NSMutableArray *players = nil;
    for (NSString *key in rosterKeys) {
        id value = NBFGetProp(self, key);
        if ([value isKindOfClass:[NSArray class]]) {
            players = [value mutableCopy];
            break;
        }
    }
    if (!players) {
        NBFLog(@"[%@] no player array — keys %@ absent, injection skipped",
               NSStringFromClass([self class]), rosterKeys);
        return;
    }

    // Slot 0 is the local player. Everything after it is replaced only after
    // at least one bot could actually be built: a failed injection must leave
    // the original roster alone rather than emptying the team.
    id localPlayer = [players firstObject];
    if (!localPlayer) {
        NBFLog(@"[%@] empty roster, injection skipped", NSStringFromClass([self class]));
        return;
    }

    NSMutableArray *bots = [NSMutableArray arrayWithCapacity:5];
    for (int slot = 0; slot < 5; slot++) {
        id bot = NBFCreateBot(slot, ranked);
        if (bot) [bots addObject:bot];
    }
    if ([bots count] == 0) {
        NBFLog(@"[%@] no bot could be created, roster untouched",
               NSStringFromClass([self class]));
        return;
    }

    NSMutableArray *filled = [NSMutableArray arrayWithCapacity:[bots count] + 1];
    [filled addObject:localPlayer];
    [filled addObjectsFromArray:bots];

    for (NSString *key in rosterKeys) {
        if (NBFHasKey(self, key)) NBFSetProp(self, key, filled);
    }

    NBFLog(@"[%@] %@: roster %lu -> %lu bots",
           NSStringFromClass([self class]), ranked ? @"ranked" : @"normal",
           (unsigned long)[players count], (unsigned long)[bots count]);
}

@end

// ---------------------------------------------------------------------------
// RANKED HOOKS
// Pick: bots get their assigned brawler. Ban: swallowed so the server's own
// ban timer resolves the phase instead of a bot sending a request.
// ---------------------------------------------------------------------------

@interface NBFRankedHook : NSObject
- (void)nbf_pickForPlayer:(id)player;
- (void)nbf_banForPlayer:(id)player;
@end

// How this build's assignBrawler:toPlayer: takes its first argument.
// 0 unknown (call nothing), 1 (id,id), 2 (int,id), 3 (long long,id).
// Calling it blind with an NSNumber where the ABI expects an int hands the
// method a pointer — that is a segfault, not an exception.
static int NBFParseBrawlerAssignEncoding(const char *types) {
    if (!types || types[0] != 'v') return 0;
    const char *p = types + 1;
    while (*p >= '0' && *p <= '9') p++;
    if (*p++ != '@') return 0;
    while (*p >= '0' && *p <= '9') p++;
    if (*p++ != ':') return 0;
    while (*p >= '0' && *p <= '9') p++;

    char first = *p;
    if (first == '@') return 1;
    if (first == 'i' || first == 'I') return 2;
    if (first == 'q' || first == 'Q') return 3;
    return 0;
}

static BOOL NBFCallBrawlerAssign(id target, SEL sel, NSNumber *brawlerId, id player) {
    Method method = class_getInstanceMethod(object_getClass(target), sel);
    if (!method) return NO;

    switch (NBFParseBrawlerAssignEncoding(method_getTypeEncoding(method))) {
        case 1: {
            typedef void (*Send)(id, SEL, id, id);
            ((Send)objc_msgSend)(target, sel, brawlerId, player);
            return YES;
        }
        case 2: {
            typedef void (*Send)(id, SEL, int, id);
            ((Send)objc_msgSend)(target, sel, [brawlerId intValue], player);
            return YES;
        }
        case 3: {
            typedef void (*Send)(id, SEL, long long, id);
            ((Send)objc_msgSend)(target, sel, [brawlerId longLongValue], player);
            return YES;
        }
        default:
            return NO;
    }
}

@implementation NBFRankedHook

- (void)nbf_pickForPlayer:(id)player {
    if (!NBFIsBotPlayer(player)) {
        [self nbf_pickForPlayer:player];
        return;
    }

    NBFConfig *cfg = [NBFConfig shared];
    int slot = NBFSlotForPlayer(player);

    NSNumber *brawlerId = @([cfg brawlerIdForSlot:slot ranked:YES]);
    NBFSetProp(player, @"brawlerId", brawlerId);
    NBFSetProp(player, @"selectedBrawler", brawlerId);

    SEL assign = NSSelectorFromString(@"assignBrawler:toPlayer:");
    if ([self respondsToSelector:assign]) {
        @try {
            if (!NBFCallBrawlerAssign(self, assign, brawlerId, player)) {
                NBFLog(@"assignBrawler:toPlayer: encoding unsupported, KVC only");
            }
        } @catch (...) {
            NBFLog(@"assignBrawler:toPlayer: threw for slot %d", slot);
        }
    }
    NBFLog(@"ranked pick: slot %d -> brawler %@", slot, brawlerId);
}

- (void)nbf_banForPlayer:(id)player {
    if (NBFIsBotPlayer(player)) {
        NBFLog(@"ban request swallowed for bot, server timer resolves it");
        return;
    }
    [self nbf_banForPlayer:player];
}

@end

// ---------------------------------------------------------------------------
// MATCH ISOLATION
// Deterministic per-install room token. FNV-1a instead of -hash: NSString's
// hash is not guaranteed stable across OS versions, and an unstable token
// would silently put you back in the public pool.
// ---------------------------------------------------------------------------

static NSString *NBFMakeRoomToken(void) {
    static NSString *token = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Foundation-only seed: the app container path is per-install and
        // NSTemporaryDirectory is available by the time a join packet is built.
        NSString *seed = [NSString stringWithFormat:@"%@-%u",
                          NSTemporaryDirectory(), arc4random()];
        if (!seed) {
            const char *home = getenv("HOME");
            seed = home ? [NSString stringWithUTF8String:home] : @"NULLS-PRIVATE";
        }

        unsigned long long hash = 1469598103934665603ULL;
        const char *bytes = [seed UTF8String];
        for (const char *p = bytes; p && *p; p++) {
            hash ^= (unsigned long long)(unsigned char)*p;
            hash *= 1099511628211ULL;
        }
        token = [NSString stringWithFormat:@"PRIV_%08llX",
                 (unsigned long long)(hash & 0xFFFFFFFFULL)];
        NBFLog(@"room token %@", token);
    });
    return token;
}

@interface NBFJoinHook : NSObject
- (void)nbf_buildJoinPacket:(id)packet;
@end

@implementation NBFJoinHook

- (void)nbf_buildJoinPacket:(id)packet {
    [self nbf_buildJoinPacket:packet];   // original packet fields first

    NBFSetProp(packet, @"roomToken", NBFMakeRoomToken());
    NBFSetProp(packet, @"privateMatch", @YES);
    NBFSetProp(packet, @"maxPlayers", @1);
}

@end


// ---------------------------------------------------------------------------
// CANDIDATE DUMP
// Writes every game-shaped class and its relevant selectors to the log. This
// is how the real names get found on a build where the defaults miss.
// ---------------------------------------------------------------------------

static NSString *NBFCandidateDumpPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (gCandidatePath[0]) {
            path = [NSString stringWithUTF8String:gCandidatePath];
        }
        if (!path) {
            NSString *tmp = NSTemporaryDirectory();
            if (tmp) path = [tmp stringByAppendingString:@"NullsBotFill-candidates.txt"];
        }
    });
    return path;
}

static void NBFDumpCandidates(void) {
    static const char *selectorTokens[] = {
        "tick", "update", "player", "battle", "match", "lobby", "room",
        "rank", "pick", "ban", "join", "brawler", "logic", "entity",
        "setup", "start", "config", "bot"
    };

    NSMutableString *out = [NSMutableString string];
    [out appendString:@"\n=== NBF candidate dump ===\n"];

    unsigned int count = 0;
    Class *classes = NBFCopyClasses(&count);
    if (!classes) return;

    int emitted = 0;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        if (!NBFNameLooksLikeGameClass(name)) continue;
        if (strncmp(name, "NBF", 3) == 0) continue;

        NSMutableString *line = [NSMutableString string];
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int m = 0; m < methodCount; m++) {
            const char *sel = sel_getName(method_getName(methods[m]));
            BOOL relevant = NO;
            for (size_t t = 0; t < sizeof(selectorTokens) / sizeof(selectorTokens[0]); t++) {
                if (strstr(sel, selectorTokens[t])) { relevant = YES; break; }
            }
            if (!relevant) continue;
            [line appendFormat:@"\n    -%s  %s", sel,
             method_getTypeEncoding(methods[m])];
        }
        if (methods) free(methods);

        if ([line length] > 0) {
            [out appendFormat:@"\n%s%@", name, line];
            emitted++;
        }
    }
    free(classes);

    [out appendFormat:@"\n=== %d classes ===\n", emitted];

    NSString *path = NBFCandidateDumpPath();
    if (path) {
        [out writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    }
    NBFLog(@"candidate dump: %d classes written to %@", emitted, path);
}


// ---------------------------------------------------------------------------
// INSTALL
// ---------------------------------------------------------------------------

// Visits classes that define (not inherit) one of the given selectors.
static void NBFScanClasses(NSArray *selectorNames,
                           void (^visit)(Class cls, SEL sel)) {
    unsigned int count = 0;
    Class *classes = NBFCopyClasses(&count);
    if (!classes) return;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        if (!NBFNameLooksLikeBattleClass(name)) continue;
        if (strncmp(name, "NBF", 3) == 0) continue;

        for (NSString *selName in selectorNames) {
            SEL sel = NSSelectorFromString(selName);
            Method own = class_getInstanceMethod(cls, sel);
            if (!own) continue;
            Class super = class_getSuperclass(cls);
            if (super && class_getInstanceMethod(super, sel) == own) continue;
            visit(cls, sel);
        }
    }
    free(classes);
}

static void NBFInstallTickHooks(void) {
    NBFConfig *cfg = [NBFConfig shared];

    for (NSString *className in cfg.tickClasses) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        for (NSString *selName in cfg.tickSelectors) {
            SEL sel = NSSelectorFromString(selName);
            Method method = class_getInstanceMethod(cls, sel);
            if (!method) continue;

            BOOL usesDouble = NO;
            if (!NBFParseTickEncoding(method_getTypeEncoding(method), &usesDouble)) {
                NBFLog(@"skip -[%s %s]: encoding %s is not a scalar tick",
                       class_getName(cls), sel_getName(sel),
                       method_getTypeEncoding(method));
                continue;
            }
            NBFInstallMethod(cls, sel, [NBFEntityHook class],
                             usesDouble ? @selector(nbf_tickD:)
                                        : @selector(nbf_tickF:));
        }
    }
}

static void NBFInstallAll(void) {
    NBFConfig *cfg = [NBFConfig shared];
    int before = gHookCount;

    // --- match setup ---
    for (NSString *className in cfg.setupClasses) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        for (NSString *selName in cfg.setupSelectors) {
            NBFInstallMethod(cls, NSSelectorFromString(selName),
                             [NBFSetupHook class],
                             @selector(nbf_applyMatchConfig:));
        }
    }

    // --- entity tick ---
    int tickBefore = gHookCount;
    NBFInstallTickHooks();

    // Nothing named matched: walk the class list for a defining class.
    if (cfg.scanUnlistedClasses && gHookCount == tickBefore) {
        NBFScanClasses(cfg.tickSelectors, ^(Class cls, SEL sel) {
            Method method = class_getInstanceMethod(cls, sel);
            if (!method) return;
            BOOL usesDouble = NO;
            if (!NBFParseTickEncoding(method_getTypeEncoding(method), &usesDouble)) return;
            NBFInstallMethod(cls, sel, [NBFEntityHook class],
                             usesDouble ? @selector(nbf_tickD:)
                                        : @selector(nbf_tickF:));
        });
    }

    // --- ranked pick / ban ---
    for (NSString *className in cfg.pickClasses) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        for (NSString *selName in cfg.pickSelectorNames) {
            NBFInstallMethod(cls, NSSelectorFromString(selName),
                             [NBFRankedHook class],
                             @selector(nbf_pickForPlayer:));
        }
        for (NSString *selName in cfg.banSelectorNames) {
            NBFInstallMethod(cls, NSSelectorFromString(selName),
                             [NBFRankedHook class],
                             @selector(nbf_banForPlayer:));
        }
    }

    // --- matchmaking join ---
    for (NSString *className in cfg.joinClasses) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        for (NSString *selName in cfg.joinSelectorNames) {
            NBFInstallMethod(cls, NSSelectorFromString(selName),
                             [NBFJoinHook class],
                             @selector(nbf_buildJoinPacket:));
        }
    }

    NBFLog(@"install pass complete: %d hooks live", gHookCount - before);
}

// ---------------------------------------------------------------------------
// ENTRY
// ---------------------------------------------------------------------------

__attribute__((constructor))
static void NBFInit(void) {
    NBFBootLog("constructor");

    // Logging and crash detection come first: if anything below or in the app
    // faults, the reason is already on disk before the app can die.
    NBFSetupPaths();
    NBFCheckPreviousRun();
    NBFInstallSignalHandlers();
    NBFWriteMarker("starting");

    NBFLog(@"=== NullsBotFill launch pid=%d home=%s ===",
           (int)getpid(), getenv("HOME") ? getenv("HOME") : "?");
    if (gLogPath[0]) NBFLog(@"log file: %s", gLogPath);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NBFBootLog("entry block");
        gBootStage = 1;
        NBFWriteMarker("booting");
        NBFInstallExceptionHandler();

        NSString *ios = nil;
        @try {
            ios = [[UIDevice currentDevice] systemVersion];
        } @catch (...) {
            ios = nil;
        }
        NBFLog(@"entry timer fired (ios %@), scanning for game classes",
               ios ? ios : @"?");

        // Surface a crash from the previous launch before doing more work.
        NBFPresentCrashAlert(0);

        NBFConfig *cfg = [NBFConfig shared];

        @try {
            if (cfg.dumpCandidates) {
                NBFDumpCandidates();
            }

            if (cfg.dryRun) {
                NBFLog(@"DryRun set — discovery only, no hooks installed");
                NBFBootLog("dry run done");
            } else {
                NBFInstallAll();

                if (gHookCount == 0) {
                    NBFLog(@"no hooks installed — this build exposes no matching ObjC "
                           @"surface. That is expected on 69.252 (battle logic is C++); "
                           @"use the native Bot matchmaking override or a C++ hook. "
                           @"Read RESEARCH.md and the candidate dump, then set real "
                           @"class names in NullsBotFill.plist if any exist.");
                }
                NBFBootLog("install done");
            }
        } @catch (id exception) {
            NBFLog(@"install aborted by exception: %@", exception);
            NBFBootLog("install exception");
        }

        gBootStage = 2;
        NBFWriteMarker("ready");
        NBFLog(@"startup complete — %d hooks live, log at %s",
               gHookCount, gLogPath[0] ? gLogPath : "(unavailable)");
    });
}

