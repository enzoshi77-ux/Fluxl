# NullsBotFill

Client-side bot filler for the Null's Brawl iOS client (arm64, iOS 14+), loaded
as a dylib by LiveContainer.

**[Download](https://github.com/enzoshi77-ux/Fluxl/releases/latest)**
— `NullsBotFill.dylib` + config plist, ad-hoc signed.

Match roster becomes: you in slot 0, five passive bots behind you. Bots walk on
a random heading, never attack, never use a super. Ranked picks are fixed per
bot and ban requests are swallowed so the server's auto-ban timer resolves the
phase. Solo Showdown and Bounty are left alone. The join packet carries a
per-device room token and `maxPlayers = 1`.

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
page on each build and fails the build on a mismatch.

## Install

1. Copy `dist/NullsBotFill.dylib` into the app bundle's `Tweaks/` folder.
   In LiveContainer: app long-press → Settings → Tweaks → add the dylib.
2. Optional: copy `NullsBotFill.plist` to the same app container's
   `Documents/` folder to override defaults.
3. Launch. Read `<container>/tmp/NullsBotFill.log` (also on the console via
   `NSLog`) for what bound and what did not.

## Verification status

Built, linked, signed, hash-verified here. Not run on a device — no iOS target
in this environment, so these are the unverified assumptions, in order of how
likely they are to bite:

| Assumption | If wrong |
|---|---|
| The client exposes ObjC classes for match setup / entity tick | zero hooks install; log says so, game is untouched |
| Bot `playerId` sits in `[BotBaseId, BotBaseId+16)` or matches `BotNames` | entities are treated as human, bots stand still |
| The entity exposes `moveX/moveY` (or one of the fallbacks) | heading is written nowhere, bots freeze; try `TickSuppressOriginal=false` |
| Brawler ids `1600000x` are valid logic ids for this build | bots spawn as default brawler or the slot fill fails |
| `roomToken` / `privateMatch` / `maxPlayers` are honored by the server | isolation silently does not apply |

The original sketch assumed names (`PlayerEntry`, `BattleManager`) that nothing
in this repo can confirm. This build resolves them at runtime instead: it dumps
every game-shaped class with its selectors to
`<tmp>/NullsBotFill-candidates.txt`, hooks the ones that exist, and logs every
skip with the reason. Feed the real names back through the plist and no rebuild
is needed.

## IPA route

`tools/patch_ipa.py` bakes the dylib into the app instead of loading it as a
tweak:

```sh
python3 tools/patch_ipa.py nb.ipa dist/NullsBotFill.dylib out.ipa
```

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
build.sh                  compile + link + verify
Makefile                  Theos alternative
sdk-stubs/                Foundation/UIKit/objc headers for SDK-less builds
tools/verify_macho.py     signature and code-page checker
dist/NullsBotFill.dylib   built output
```
