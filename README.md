# NullsBotFill

Client-side bot filler for the Null's Brawl iOS client (arm64, iOS 14+), loaded
as a dylib by LiveContainer.

**[Download](https://github.com/enzoshi77-ux/Fluxl/releases/latest)**
— `NullsBotFill.dylib` + config plist, ad-hoc signed.

Target behavior (only on a build that exposes an Objective-C roster — `69.252`
does not, see [Research](#research-bots-and-matchmaking)): match roster becomes
you in slot 0, five passive bots behind you. Bots walk on a random heading,
never attack, never use a super. Ranked picks are fixed per bot and ban requests
are swallowed so the server's auto-ban timer resolves the phase. Solo Showdown
and Bounty are left alone. The join packet carries a per-device room token and
`maxPlayers = 1`.

## Build

```sh
./build.sh
```

- Linux or macOS, no Apple SDK required: clang + `ld64.lld`, headers from
  `sdk-stubs/`. Output `dist/NullsBotFill.dylib`, ad-hoc signed by the linker.
- With an iPhoneOS SDK present (`xcrun`), the real headers are used instead.
- `CLANG=`, `LD64LLD=`, `SDK=` override tool discovery.
- `make` is there for Theos setups; it is not required.

`dist/NullsBotFill.dylib` is arm64 `MH_DYLIB`, `LC_CODE_SIGNATURE` present,
`CS_ADHOC | CS_LINKER_SIGNED`. `tools/verify_macho.py` re-hashes every code
page on each build and fails the build on a mismatch. `tools/verify_plist.py`
runs first and rejects wrong types, missing slots, duplicate/negative ids, an
empty brawler list, or a `16000000` id; add
`--characters res/csv_logic/characters.csv` to resolve ids to row names.

## Install

1. Copy `dist/NullsBotFill.dylib` into the app bundle's `Tweaks/` folder.
   In LiveContainer: app long-press → Settings → Tweaks → add the dylib.
2. Optional: copy `NullsBotFill.plist` to the same app container's
   `Documents/` folder to override defaults.
3. Launch. Read `<container>/tmp/NullsBotFill.log` (also on the console via
   `NSLog`) for what bound and what did not.

## Research: bots and matchmaking

`RESEARCH.md` documents the investigation behind this build: 2020–2023 Null's
Brawl forum/patch records, the current `69.252` client, its game data, and the
public v41 server implementation. Key findings:

- Null's bots were a **client-side offline Friendly Game** feature. In 2020 the
  forum staff confirmed that all Friendly Games run on the game client, that
  bots cannot be disabled in offline battle, and that events/maps were removed
  to make offline battles work. Online friendly battles arrived in 2023.
- Matchmaking pairs by trophies and widens the allowed trophy difference while
  you wait (Null's patch notes, 2021-08-26). The public v41 queue starts on a
  timer with at least one player or immediately when full, and does not append
  bots server-side.
- `OFFLINE_BOT_BRAWLER` is **empty** in every public game-data dump (v36–v69),
  including Null's own `globals.csv`. The real offline-bot loadout is the
  `OfflineBrawler`/`OfflineSkin`/`OfflineLevel` key block in the binary.
- The `69.252` client still has a native **`Bot matchmaking override`**
  (REMOVED / ALWAYS PLAY WITH BOTS / NEVER PLAY WITH BOTS) and a
  `Force AI bot` toggle. That, or a C++ hook, is the correct bot switch — not
  Objective-C roster injection. The client has zero ObjC battle classes.
- Brawlers are encoded as `GlobalId(16, row)`, so `1600000x` in the old plist
  were not valid character ids. The defaults are now row indices `0..4` and
  `5..9`; bot player ids use the observed `10000100+` range.

## Verification status

Built, linked, signed, hash-verified here. Not run on a device — no iOS target
in this environment, so these are the unverified assumptions, in order of how
likely they are to bite:

| Assumption | Reality on `69.252` / if wrong |
|---|---|
| The client exposes ObjC classes for match setup / entity tick | **Measured false** on `69.252`: 0 battle classes in ObjC or Swift. Zero hooks install; log says so, game is untouched. A C++ hook or the native bot override is required. |
| Bot `playerId` sits in `[BotBaseId, BotBaseId+16)` or matches `BotNames` | Best-effort synthetic range (`10000100+`). If the client assigns its own ids, entities are treated as human and bots stand still. |
| The entity exposes `moveX/moveY` (or one of the fallbacks) | Unverified. If absent, heading is written nowhere and bots freeze; try `TickSuppressOriginal=false`. |
| Brawler ids are valid logic ids | Defaults are now `characters.csv` row indices `0..4` / `5..9`, encoded by the client as `GlobalId(16,row)`. The old `1600000x` values are not valid character ids. If the property expects a `LogicData` object rather than an integer, KVC logs a skip. |
| `roomToken` / `privateMatch` / `maxPlayers` are honored by the server | Unverified; isolation silently does not apply if not. |
| Native `Bot matchmaking override` is usable from this dylib | Not hooked by this build. It exists in the binary (REMOVED / ALWAYS / NEVER) and is the correct future switch; its address moves with every client. |

The original sketch assumed names (`PlayerEntry`, `BattleManager`) that nothing
in this repo can confirm. This build resolves them at runtime instead: it dumps
every game-shaped class with its selectors to
`<tmp>/NullsBotFill-candidates.txt`, hooks the ones that exist, and logs every
skip with the reason. Feed the real names back through the plist and no rebuild
is needed.

### Crash fixes in this revision

The source is valid and compiles clean; these are the paths that could fault
after a hook installs:

- Swizzling an inherited method now gives the target its own copy and refuses
  a second install on a descendant. Before, two configured classes in the same
  hierarchy could exchange two hook IMPs and recurse until the stack overflowed.
- Setup / pick / ban / join hooks validate the method encoding and only install
  for `(void, self, SEL, id)`. Passing an `NSNumber` to an `int` argument is an
  ABI fault that `@try` cannot catch. Tick hooks check float vs double.
- Empty brawler arrays no longer index `objectAtIndex:-1`; slots are clamped.
- Plist overrides are type-checked (array/string/number) and ignored with a log
  entry instead of raising.
- The original roster is replaced only if at least one bot was created; a
  failed factory no longer empties the team.
- Bot allocation, player-id writes, and `playerId` conversion are guarded; the
  ranked slot falls back through associated slot → property → `playerId-base`.

## IPA route

`tools/patch_ipa.py` bakes the dylib into the app instead of loading it as a
tweak:

```sh
python3 tools/patch_ipa.py nb.ipa dist/NullsBotFill.dylib out.ipa
```

If the IPA already contains the load command and a
`Frameworks/NullsBotFill.dylib` entry (for example a previous packaging
release), replace just that entry instead of injecting it again:

```sh
python3 tools/replace_ipa_dylib.py old.ipa dist/NullsBotFill.dylib new.ipa
```

That rewrites the dylib member only, verifies its SHA-256, and keeps the zip at
one dylib entry instead of creating a duplicate.

It inserts `LC_LOAD_DYLIB @rpath/NullsBotFill.dylib` into the main binary
(using header padding, no shifting), copies the dylib to
`Payload/NB.app/Frameworks/`, re-signs the binary ad-hoc with the original
entitlements and exec-segment fields, and rewrites `__LINKEDIT` to cover the
new signature. The result still has to be signed with the certificate that
signed LiveContainer before it will install.

Why this is better than the tweak folder: the load command is applied by dyld
when the guest binary is mapped, so there is no tweak-loader timing, no second
dylib injection step, and no dependency on LiveContainer's tweak list.

Why it does not help on its own: the mod inside is still the ObjC mod. See the
next section for what this client actually exposes.

## What this specific client exposes

Measured on `nb_69.252_4cc76283.ipa`:

| Check | Result |
|---|---|
| ObjC classes in the main binary | 739, all Zendesk / Firebase / Sentry / AppsFlyer / Recaptcha |
| Swift types | 355, same set of SDKs |
| Battle classes in ObjC or Swift | 0 |
| Engine | C++: `LogicBattleModeClient`, `LogicPlayer`, `LogicCharacter`, `LogicGameObjectManager` |
| Main binary | 18 MB, thin arm64, `cryptid 0`, 132 load commands |
| Existing instrumentation | `Frameworks/Frida.framework/W.dylib` + compiled `updated/script_69_252.js`, `config.json` gated by `res/license.bin` |

So on this build the ObjC hook set installs nothing. The dylib loads, dumps the
candidate list, logs `no hooks installed`, and the game behaves as vanilla.
That is not a crash and not a bug in the loader: there is simply no ObjC battle
surface to swizzle.

The string lead was checked too. `OFFLINE_BOT_BRAWLER` is referenced once, at
`0x1009bca8c`, inside a config-key loader that reads brawler CSV columns into
fields `+0xd8 .. +0x100` of a per-brawler struct. It is a data column name, not
the roster constructor, so it is not the hook point.

A working bot fill on this client needs one of:

1. A C++ hook on the battle creation path, found from the server join response,
   not from a string. That means reading the deserialiser for the join packet
   and the function that materialises `LogicPlayer` objects from it.
2. The client's own script platform: `config.json` points the bundled Frida
   gadget at `updated/script_69_252.js`. That script is compiled bytecode and
   license-gated, but the gadget itself is present and is the natural place for
   a C++ `Interceptor` hook if you control the script path.

Both need the binary in a debugger. Neither is a dylib the way the original
sketch assumed.

For reference, the C++ route once a debugger is attached: locate the join-packet
deserialiser and the `LogicPlayer` materialisation, hook with `MSHookFunction`
(ElleKit/Substrate) or Dobby at a resolved address, never a fixed offset —
offsets move every client update. Bot input lives in the per-frame logic tick;
write the movement vector into the player's input struct before the AI pass, or
skip the AI pass.

## Crash logs

The app's own crash report:

| Setup | Where |
|---|---|
| iOS, no jailbreak | Settings → Privacy & Security → Analytics & Improvements → Analytics Data → search the app name. Requires "Share iPhone Analytics" to be on. |
| Xcode | Window → Devices and Simulators → pick device → View Device Logs |
| macOS, synced | `~/Library/Logs/CrashReporter/MobileDevice/<device name>/` |
| Windows, synced | `%APPDATA%\Apple Computer\Logs\CrashReporter\MobileDevice\<device name>\` |
| Linux | `idevicecrashreport -u <udid> -e ./crashes` (libimobiledevice) |
| Jailbroken | `/var/mobile/Library/Logs/CrashReporter/` |

In the `.ips`, the three fields that matter: `Exception Type`, `Termination
Reason`, and `Last Exception Backtrace`. Then check `Binary Images` for
`NullsBotFill.dylib` — if it is listed, the dylib loaded and the crash came
after load.

The tweak's own log:

```
<LiveContainer data container>/Documents/Applications/<bundle id>/tmp/NullsBotFill.log
<...>/tmp/NullsBotFill-candidates.txt
```

In LiveContainer's Files view: LiveContainer → the app → its data folder → tmp.
Also on the console as `[NBF]` lines: `idevicesyslog -u <udid> | grep NBF`, or
Console.app with the device selected.

If `NullsBotFill.log` does not exist at all, the crash happened before the
tweak's 0.75 s entry timer — that rules out every hook and points at load:
wrong architecture, signature, or a missing dependency.

## If it crashes

1. Set `DryRun` to `true` in the plist, relaunch.
2. Still crashes → load path, not our hooks. Check `file dist/NullsBotFill.dylib`
   reports arm64 and that LiveContainer is not refusing the signature.
3. No longer crashes → a hook is the cause. The log names every hook that
   installed, in order; the last one before the crash is the suspect. Remove
   that class from the matching list in the plist and relaunch — no rebuild.
4. Send the log plus the `.ips` back with the last `[NBF]` line intact.


`BotBrawlerIds`, `RankedBrawlerIds`, `BotNames`, `BotBaseId`, `WalkInterval`,
`RankedEnabled`, `TickSuppressOriginal`, `DumpCandidates`, `DryRun`,
`ScanUnlistedClasses`, `ExcludedModes`, `PlayerClasses`, `SetupClasses`,
`SetupSelectors`, `TickClasses`, `TickSelectors`, `PickClasses`,
`PickSelectors`, `BanSelectors`, `JoinClasses`, `JoinSelectors`.

`TickSuppressOriginal = true` drops the game's tick for bots (your spec: walk
only). If bots do not move, set it to `false`: the game tick runs with attack
intents cleared first, which keeps physics and animation alive.

## Layout

```
NullsBotFill.m            source
NullsBotFill.plist        optional runtime config
RESEARCH.md               bots/matchmaking sources and 69.252 measurements
build.sh                  compile + link + verify
Makefile                  Theos alternative
sdk-stubs/                Foundation/UIKit/objc headers for SDK-less builds
tools/verify_macho.py     signature and code-page checker
tools/verify_plist.py     plist type/slot/brawler-id checker
tools/replace_ipa_dylib.py update a dylib already baked into an IPA
dist/NullsBotFill.dylib   built output
```
