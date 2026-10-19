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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSString *const kLogFileName    = @"NullsBotFill.log";
static NSString *const kConfigFileName = @"NullsBotFill.plist";

static NSString *NBFLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *tmp = NSTemporaryDirectory();
        if (tmp) path = [tmp stringByAppendingString:kLogFileName];
    });
    return path;
}

static void NBFLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *message = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSLog(@"[NBF] %@", message);

    NSString *path = NBFLogPath();
    if (!path) return;
    FILE *fp = fopen([path UTF8String], "a");
    if (!fp) return;
    fputs([[message stringByAppendingString:@"\n"] UTF8String], fp);
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

+ (instancetype)shared;
- (int)brawlerIdForSlot:(int)slot ranked:(BOOL)ranked;
@end


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

    self.botBrawlerIds = @[ @16000000, @16000001, @16000002, @16000003, @16000004 ];
    self.rankedBrawlerIds = @[ @16000005, @16000006, @16000007, @16000008, @16000009 ];
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

    self.botBaseId = 900100;
    self.walkInterval = 1.5f;
    self.rankedEnabled = YES;
    self.tickSuppressOriginal = YES;
    self.dumpCandidates = YES;
    self.scanUnlistedClasses = YES;

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
        if ((value = [dict objectForKey:@"BotBrawlerIds"]))    self.botBrawlerIds = value;
        if ((value = [dict objectForKey:@"RankedBrawlerIds"])) self.rankedBrawlerIds = value;
        if ((value = [dict objectForKey:@"BotNames"]))         self.botNames = value;
        if ((value = [dict objectForKey:@"ExcludedModes"]))    self.excludedModes = value;
        if ((value = [dict objectForKey:@"PlayerClasses"]))    self.playerClasses = value;
        if ((value = [dict objectForKey:@"SetupClasses"]))     self.setupClasses = value;
        if ((value = [dict objectForKey:@"SetupSelectors"]))   self.setupSelectors = value;
        if ((value = [dict objectForKey:@"TickClasses"]))      self.tickClasses = value;
        if ((value = [dict objectForKey:@"TickSelectors"]))    self.tickSelectors = value;
        if ((value = [dict objectForKey:@"PickClasses"]))      self.pickClasses = value;
        if ((value = [dict objectForKey:@"PickSelectors"]))    self.pickSelectorNames = value;
        if ((value = [dict objectForKey:@"BanSelectors"]))     self.banSelectorNames = value;
        if ((value = [dict objectForKey:@"JoinClasses"]))      self.joinClasses = value;
        if ((value = [dict objectForKey:@"JoinSelectors"]))    self.joinSelectorNames = value;

        if ((value = [dict objectForKey:@"BotBaseId"]))        self.botBaseId = [value intValue];
        if ((value = [dict objectForKey:@"WalkInterval"]))     self.walkInterval = [value floatValue];
        if ((value = [dict objectForKey:@"RankedEnabled"]))    self.rankedEnabled = [value boolValue];
        if ((value = [dict objectForKey:@"TickSuppressOriginal"]))
            self.tickSuppressOriginal = [value boolValue];
        if ((value = [dict objectForKey:@"DumpCandidates"]))
            self.dumpCandidates = [value boolValue];
        if ((value = [dict objectForKey:@"ScanUnlistedClasses"]))
            self.scanUnlistedClasses = [value boolValue];

        NBFLog(@"config loaded from %@", path);
        return;
    }

    NBFLog(@"no config plist found, using built-in defaults");
}

- (int)brawlerIdForSlot:(int)slot ranked:(BOOL)ranked {
    NSArray *source = ranked ? self.rankedBrawlerIds : self.botBrawlerIds;
    if (![source isKindOfClass:[NSArray class]] || slot < 0) return 0;
    if ((NSUInteger)slot >= [source count]) slot = (int)([source count] - 1);
    return [[source objectAtIndex:(NSUInteger)slot] intValue];
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
    if (!game || !hook) return NO;

    class_addMethod(target, hookSel,
                    method_getImplementation(hook),
                    method_getTypeEncoding(hook));

    Method installed = class_getInstanceMethod(target, hookSel);
    if (!installed) return NO;

    // If addMethod failed and the selector resolves to a superclass method,
    // installing would rewrite the superclass for every subclass. Bail.
    Class super = class_getSuperclass(target);
    if (super && class_getInstanceMethod(super, hookSel) == installed) {
        NBFLog(@"skip -[%s %s]: hook selector resolves outside the class",
               class_getName(target), sel_getName(gameSel));
        return NO;
    }
    if (method_getImplementation(installed) != method_getImplementation(hook)) {
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
    if (pid) {
        long long value = [pid longLongValue];
        if (value >= cfg.botBaseId && value < (long long)cfg.botBaseId + 16) return YES;
    }

    NSString *name = NBFGetProp(object, @"name");
    if ([name isKindOfClass:[NSString class]]) {
        for (NSString *botName in cfg.botNames) {
            if ([name isEqualToString:botName]) return YES;
        }
    }
    return NO;
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

// A class is usable only if an instance accepts the synthetic playerId write.
static BOOL NBFProbePlayerClass(Class cls) {
    if (!cls) return NO;
    @try {
        id probe = [[cls alloc] init];
        if (!probe) return NO;
        [probe setValue:@1 forKey:@"playerId"];
        return YES;
    } @catch (...) {
        return NO;
    }
}

static Class NBFResolvePlayerClass(void) {
    if (gPlayerClassResolved) return gPlayerClass;
    gPlayerClassResolved = YES;

    NBFConfig *cfg = [NBFConfig shared];

    for (NSString *name in cfg.playerClasses) {
        Class cls = NSClassFromString(name);
        if (cls && NBFProbePlayerClass(cls)) {
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
                if (NBFProbePlayerClass(classes[i])) {
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
    if ((NSUInteger)slot >= [cfg.botNames count]) return nil;

    id bot = [[cls alloc] init];
    if (!bot) return nil;

    NSNumber *brawlerId = @([cfg brawlerIdForSlot:slot ranked:ranked]);
    NSNumber *playerId  = @(cfg.botBaseId + slot);

    NBFSetProp(bot, @"playerId", playerId);
    NBFSetProp(bot, @"playerID", playerId);
    NBFSetProp(bot, @"name", [cfg.botNames objectAtIndex:(NSUInteger)slot]);
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

    // Slot 0 is the local player. Everything after it is replaced.
    id localPlayer = [players firstObject];
    [players removeAllObjects];
    if (localPlayer) [players addObject:localPlayer];

    int added = 0;
    for (int slot = 0; slot < 5; slot++) {
        id bot = NBFCreateBot(slot, ranked);
        if (!bot) break;
        [players addObject:bot];
        added++;
    }

    for (NSString *key in rosterKeys) {
        if (NBFHasKey(self, key)) NBFSetProp(self, key, players);
    }

    NBFLog(@"%@ %@: roster %lu -> %d bots",
           NSStringFromClass([self class]), ranked ? @"ranked" : @"normal",
           (unsigned long)[players count], added);
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

@implementation NBFRankedHook

- (void)nbf_pickForPlayer:(id)player {
    if (!NBFIsBotPlayer(player)) {
        [self nbf_pickForPlayer:player];
        return;
    }

    NBFConfig *cfg = [NBFConfig shared];
    int slot = [NBFGetProp(player, @"botSlot") intValue];
    if (slot < 0) slot = 0;
    if (slot > 4) slot = 4;

    NSNumber *brawlerId = @([cfg brawlerIdForSlot:slot ranked:YES]);
    NBFSetProp(player, @"brawlerId", brawlerId);
    NBFSetProp(player, @"selectedBrawler", brawlerId);

    SEL assign = NSSelectorFromString(@"assignBrawler:toPlayer:");
    if ([self respondsToSelector:assign]) {
        typedef void (*NBFTwoObjectSend)(id, SEL, id, id);
        @try {
            ((NBFTwoObjectSend)objc_msgSend)(self, assign, brawlerId, player);
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
        NSString *seed = nil;
        @try {
            seed = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
        } @catch (...) {
            seed = nil;
        }
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
        NSString *tmp = NSTemporaryDirectory();
        if (tmp) path = [tmp stringByAppendingString:@"NullsBotFill-candidates.txt"];
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NBFConfig *cfg = [NBFConfig shared];
        NBFLog(@"NullsBotFill loaded, scanning for game classes");

        if (cfg.dumpCandidates) {
            NBFDumpCandidates();
        }

        NBFInstallAll();

        if (gHookCount == 0) {
            NBFLog(@"no hooks installed — this build exposes no matching ObjC "
                   @"surface; read the candidate dump and set the class names "
                   @"in NullsBotFill.plist");
        }
    });
}

