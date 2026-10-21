# Null's Brawl: bots and matchmaking — research notes

Research date: 2026-10-20. Client inspected: Null's Brawl `69.252`
(`NullsBrawl-69.252-NBF.ipa`, sha256
`14b799f580787f7b254b316167098657eb0d0c25a19390e510107d72ad3fe46e`).

This answers two questions: whether the dylib is "all invalid code", and what
actually happened to bots and matchmaking on Null's Brawl.

## Short answer

The dylib is valid arm64 Objective-C. It compiles, links, signs, and
`tools/verify_macho.py` re-hashes every code page. It does **not** crash this
client by itself. What it cannot do is reach the battle logic: the `69.252`
binary contains no Objective-C or Swift battle classes. All of it is C++
(`LogicBattleModeClient`, `LogicPlayer`, `LogicCharacter`,
`LogicGameObjectManager`). A dylib that installs zero hooks is the measured
result, not a crash. Any crash before `NullsBotFill.log` exists is a load-path
problem (architecture, signature, dependency), not invalid source.

The native bot switch is still inside the client. The binary has a
`Bot matchmaking override` setting with three states:

```
Bot matchmaking override
REMOVED: default environment setting is used
Bot matchmaking override
ALWAYS PLAY WITH BOTS
Bot matchmaking override
NEVER PLAY WITH BOTS
```

and a separate `Force AI bot ENABLED./DISABLED.` toggle. The option is read from
offset `+0x90` of the settings object in the formatter around `0x10075e6b0` in
the current binary (strings `0x100ec28c3`, `0x100ec28f2`, `0x100ec2920`). This
is the supported developer switch for bot matchmaking; injecting ObjC roster
entries is the wrong layer for this build.

## Timeline of bots on Null's Brawl

The useful records are the 2020–2021 forum posts and patch notes, not the
current marketing page.

| Date | Record | What it establishes |
|---|---|---|
| 2020-11-22 | [“So many problems with Null's Brawl”](https://web.archive.org/web/20250123065909/https://forum.dnull.xyz/t/so-many-problems-with-nulls-brawl/170463) | Bots move before the match starts. Friendly games run on the **game client**, not a battle server. Removing the bot prevents playing with a friend, because the offline battle code has no way to run without bots. Events and maps were removed “due to correctly working offline battles”. |
| 2020-12-03 | [“How can I play with only bots?”](https://web.archive.org/web/20250218230919/https://forum.dnull.xyz/t/how-can-i-play-with-only-bots/172071) | Bots are a **Friendly Game / offline client-side** feature. Disabling bots is only available in online mode. |
| 2021-08-26 | [Server improvements before the Ash update](https://nulls-brawl.com/improvements-on-the-null-s-brawl-server-before-the-upgrade-with-ash/) | Battle logic was rewritten server-side. Matchmaking now picks opponents by trophies and **gradually increases the allowed trophy difference** while you wait. Boss modes returned. |
| 2023-03-23 | [Duels in friendly battles](https://nulls-brawl.com/implemented-duels-in-friendly-battles-and-other-on-null-s-brawl/) | Online friendly battles between friends were implemented, replacing the old bot-only offline friendly flow. |
| 2025–2026 | [Official Null's Brawl page](https://nulls.gg/servers/nulls-brawl/) | “Bots are... boring. Luckily, we have great multiplayer support.” Current client is `69.252`. |

A community explanation of the client split is consistent with this:
[Brawl Stars removed the offline logic after v29 except for the tutorial](https://www.reddit.com/r/brawlstarsmodding/comments/132irxr/how_nulls_brawl_works/),
so private servers had to reimplement online battle logic, and Null's uses
Frida to inject its own code. On the current iOS build that Frida payload is
`Frameworks/Frida.framework/W.dylib` plus a compiled
`updated/script_69_252.js`; the readable strings in it are the mod URL,
license file, and battle-server health checks, not a bot roster.

So “they removed the bots” is not a single switch that was flipped. The old
bots lived in Supercell's client-side offline battle code. Null's moved
friendly games to real battle servers over 2021–2023, and the remaining bot
path is the client's native offline/AI path, still exposed by the
`Bot matchmaking override` and `Force AI bot` developer settings.

## Matchmaking logic

The public emulator closest to the protocol (`BSL.v41`) shows the shape of a
Null's-style queue in
[`MatchmakingManager.cs`](https://github.com/LkPrtctrd/BSL.v41/blob/main/BSL.v41.General/NetIsland/MatchmakingManager.cs):
one manager per event slot, `maxPlayersCount` from the game mode, a countdown
of `maxPlayersCount * SearchTimeFactor`, `MatchMakingStatusMessage` carrying
seconds/found/max, and a start when the timer expires with at least one player
or immediately when full. No bot players are appended by the queue: the list
named `logicPlayerMapWithBots` receives only real `ServerConnection` players.
Null's own 2021 note adds the one behaviour the emulator does not have:
pairing by trophies with a widening search range.

The client-side `LogicPlayer` wire format explains the ID mistakes in this
repo. In the same emulator's
[`LogicPlayer.cs`](https://github.com/LkPrtctrd/BSL.v41/blob/main/BSL.v41.Logic/Environment/LaserMessage/Sepo/Player/LogicPlayer.cs),
a bot is encoded as player id `10000000 + random(100..200)`, and a brawler is
`GlobalId.CreateGlobalId(16, HeroInfo[0])` — a data reference whose low bits
are the row index in `characters.csv`, not `16000000`.

`16000000` is not a character id in any of the 36 public copies of
`globals.csv`/`characters.csv` searched (v36 through v69), including Null's
own published CSV dump. `NullsBotFill.plist` therefore now uses playable row
indices `0..4` and `5..9`, not `1600000x`; bot player ids use the observed
`10000100+` range.

## What the game data actually contains

`res/csv_logic/globals.csv` in the `69.252` IPA is identical to the
2025-11-30 copy in
[`nulls-brawl-site/nulls-site`](https://github.com/nulls-brawl-site/nulls-site/blob/5564789c9dc4a5b5e501da7e7d0b84bfa56b11ae/csv/globals.csv):

```
"OFFLINE_RAID_DIFFICULTY",3,,,,
"OFFLINE_BOT_BRAWLER",,,,,
"OFFLINE_TEAM",-1,,,,
```

`OFFLINE_BOT_BRAWLER` is empty in every public dump checked (`LkPrtctrd/BSL.v41`,
`LekmaDev/Brawl-Stars-Server-V36/V37`, `ShadowwDev/BrawlStars-v36/v37`,
`SparkyDev9339/BSVS-V58/V59`, `spz2020/ProjectColette-public`, and 28 others).
It is a global slot, not a brawler-id source. The values `16000000..16000009`
in the old plist were not derived from it.

The character table is the real source. The IPA has 456 rows (0..455). Its NPC
bot characters are:

| Row | Name |
|---:|---|
| 223 | `BossBot` |
| 224 | `MeleeBot` |
| 225 | `RangedBot` |
| 226 | `MeleeFastBot` |
| 18 | `BarrelBot` |
| 111 | `TutorialDummy` |

Those are NPC characters, not playable brawlers. For passive player-slot bots,
rows `0..4` (`ShotgunGirl`, `Gunslinger`, `BullDude`, `RocketGirl`,
`TrickshotDude`) are the safer defaults.

The binary also registers a dedicated offline-bot loadout block:

```
OfflineBrawler, OfflineBrawler2, OfflineBrawler3
OfflineSkin, OfflineStarPower, OfflineGadget
OfflineGear1, OfflineGear2, OfflineLevel
OfflineHeroUnlockMode, OfflineGameModeIndex, OfflineLocationIndex
```

These keys are inserted into the config map by the function at `0x10076dd90`.
They are the knobs the client reads for an offline bot's brawler, skin, star
power, gadget, gears, level, unlock mode, mode, and map. `OFFLINE_BOT_BRAWLER`
is a different, empty global; do not confuse the two.

## Why the current dylib cannot fill this client

Measured on the `69.252` main binary (18,098,864 bytes, arm64 `MH_EXECUTE`):

- 739 Objective-C classes: Zendesk, Firebase, Sentry, AppsFlyer, Recaptcha,
  Usercentrics, Helpshift. No `BattleManager`, `PlayerEntry`, `LogicPlayer`,
  `BattleEntity`, `RankedPickManager`, `MatchmakingManager` Objective-C class.
- 355 Swift types: the same SDK surface.
- Battle code is C++: `LogicBattleModeClient`, `LogicPlayer`,
  `LogicGameObjectManager`, `LogicCharacter`, `LogicBattleModeServer` peers.
- The only bot-related native setting is `Bot matchmaking override`
  (REMOVED / ALWAYS / NEVER) plus `Force AI bot`.

Consequences:

1. `NullsBotFill.m` installs zero hooks. The log says
   `no hooks installed — this build exposes no matching ObjC surface`, which is
   correct and is not a crash.
2. The plist class names (`PlayerEntry`, `BattleManager`, ...) are placeholders
   from the original sketch. They do not exist in this build.
3. `brawlerId`/`playerId` KVC writes only matter if a matching ObjC player class
   exists. On `69.252` they never run.
4. A real bot fill needs either the native `Bot matchmaking override` or a C++
   hook on the join-packet deserialiser / `LogicPlayer` materialisation. The
   addresses in this document are for `69.252` only and move with every client
   update; resolve them from the Mach-O at runtime, never hard-code them.


## Load-time crash: code-page size

The first builds were ad-hoc signed by `ld64.lld` with 4 KB code slots
(`pageShift 12`, 29 slots for 118 KB). iOS arm64 expects **16 KB** code pages:
the vendor frameworks in this IPA are signed with pageShift 14 (for example
`Sentry`, 2 slots for 34 KB). AMFI rejects a 4 KB-signed image before dyld runs
its constructor, so the app dies with no `[NBF]` line and no tweak log. This is
a packaging fault, not an Objective-C fault.

`tools/sign_dylib.py` now rewrites the dylib signature at 16 KB (8 slots), and
`tools/resign_macho.py` does the same for the app's main binary
(`nt.nb.ios`, 1097 slots). The IPA's main binary and dylib both verify at
page 16384. `NBFBootLog` writes `<tmp>/NullsBotFill-boot.log` with plain C
before any Objective-C call, so a future load failure can be separated from a
hook/entry failure.


## Crash audit of this dylib

The source was reviewed and the following real crash paths were fixed. None of
them is a syntax error, and none is proven to have caused a device crash; they
are the paths that could fault after a hook installs.

| Path | Failure | Fix |
|---|---|---|
| Swizzling an inherited method | `method_exchangeImplementations` edits the superclass, so a second configured subclass can swap two hook IMPs and call itself until the stack overflows | Materialise an own copy on the target, refuse a second install on a descendant, and bail if the trampoline selector already resolves outside the class |
| `assignBrawler:toPlayer:` / setup / pick / ban / join signatures | Passing an `NSNumber` to an `int` parameter, or a one-argument trampoline to a two-argument method, is an ABI fault that `@try` cannot catch | Parse the method encoding; only install `(void,id,SEL,id)` hooks (and only the matching float/double tick variant) |
| Empty `BotBrawlerIds` / `RankedBrawlerIds` | `objectAtIndex:(NSUInteger)-1` throws `NSRangeException` | Clamp slot, return `0` when the array is empty |
| Malformed plist arrays | `for (NSString *s in cfg.botNames)` on a string raises, and `objectAtIndex:` on a non-array raises | Type-check every override; fall back to compiled defaults and log the ignored key |
| Roster replacement with no bot factory | The original roster is cleared before the first bot is created; if `NBFCreateBot` returns `nil`, the team is left empty | Build bots into a temporary array and only replace the roster if at least one exists |
| Unknown player class allocation | `[[cls alloc] init]` on a C++-backed Supercell class can fault below `@try` | Keep the property probe, guard `isKindOfClass:`, and require a writable player id before injection |
| `playerId` of an unexpected class | `[pid longLongValue]` on `NSData`/`NSArray` raises | `respondsToSelector:` before converting |
| Bot slot lookup | A missing `botSlot` becomes `0` via `nil intValue`, so every ranked bot gets slot 0 | Read the associated slot, then the property, then `playerId - BotBaseId`, then clamp |

## Verification performed

- `./build.sh` with Debian clang 14 + `ld64.lld`, then `tools/sign_dylib.py`:
  arm64 `MH_DYLIB`, ad-hoc signature with **16 KB pages**, 8 code slots
  hash-verified. No compiler warnings.
- `tools/verify_macho.py dist/NullsBotFill.dylib`: `result: OK`, page 16384.
- The IPA main binary is re-signed with 16 KB pages (1097 slots, identifier
  `nt.nb.ios`); its `LC_LOAD_DYLIB @rpath/NullsBotFill.dylib` is present once.
- The C type-encoding parser extracted from the source and compiled on the host:
  10/10 cases (`v@:@`, `v24@0:@16`, `v@:@"NSString"`, `v@:i`, `v@:`,
  `v@:@@`, `i@:@`, `v@:f`, NULL).
- Plist parsed with Python `plistlib`; brawler ids checked against the 456-row
  `characters.csv` from the IPA.
- Mach-O strings/xrefs from the IPA: `Bot matchmaking override`,
  `ALWAYS PLAY WITH BOTS`, `NEVER PLAY WITH BOTS`, `Force AI bot`,
  `OFFLINE_BOT_BRAWLER`, `Offline*` keys, and the absence of ObjC battle
  classes.

## Sources

- Null's Brawl official: <https://nulls.gg/servers/nulls-brawl/>
- Forum thread, 2020-11-22 (Wayback):
  <https://web.archive.org/web/20250123065909/https://forum.dnull.xyz/t/so-many-problems-with-nulls-brawl/170463>
- Forum thread, 2020-12-03 (Wayback):
  <https://web.archive.org/web/20250218230919/https://forum.dnull.xyz/t/how-can-i-play-with-only-bots/172071>
- Patch notes, 2021-08-26:
  <https://nulls-brawl.com/improvements-on-the-null-s-brawl-server-before-the-upgrade-with-ash/>
- Friendly battles, 2023-03-23:
  <https://nulls-brawl.com/implemented-duels-in-friendly-battles-and-other-on-null-s-brawl/>
- Community explanation of the v29 offline-logic removal:
  <https://www.reddit.com/r/brawlstarsmodding/comments/132irxr/how_nulls_brawl_works/>
- Null's game data (`globals.csv`, `characters.csv`):
  <https://github.com/nulls-brawl-site/nulls-site>
- Public matchmaking/player implementation (v41 emulator):
  <https://github.com/LkPrtctrd/BSL.v41>
- This project's `69.252` IPA:
  <https://github.com/enzoshi77-ux/Fluxl/releases/tag/v1.0.2-ipa>

