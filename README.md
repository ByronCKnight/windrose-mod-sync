# Windrose Mod Sync

Keeps Windrose clients on exactly the mod set the server runs.

Players run `WindroseSync.exe` instead of launching the game directly. It compares
their mod folder against a published manifest, downloads what changed, deletes what's
stale, and starts the game. Windrose has no official mod support, so all of this sits
on top of UE4SS.

## Why a launcher, and not something in-game

UE4SS mods and `.pak` files mount at **engine startup**. Anything delivered while the
game is running cannot take effect until a restart, so the sync has to happen before
the game launches. A launcher is the only place that works.

## Enforcement: what this does and does not do

The launcher guarantees a **correct client** for anyone who uses it. It does **not**
stop someone who bypasses it and launches Windrose directly.

Server-side kicking was investigated and **ruled out** — see
[docs/enforcement-findings.md](docs/enforcement-findings.md). Short version: UE4SS Lua
cannot send Server RPCs across the network. It silently executes the local
`_Implementation` instead, so a client-side Lua mod has no way to signal the server.
This was proven empirically, and one attempt (`ServerChangeName`) corrupted a client
account database because the call ran locally against persistent state.

Reviving enforcement would need a compiled **C++** UE4SS mod that can route an RPC
properly. That's plausible — CampDeposit and the Enforcer's InventoryGuard are both
C++ UE4SS mods running on Windrose — but it is a separate project.

## Layout

```
payload/client/     installed on players' PCs by the launcher
payload/server/     uploaded to the game server by hand (SFTP)
tools/publish.ps1   regenerates manifest.json
tools/verify.ps1    breaks a client on purpose and checks the launcher repairs it
launcher/           WindroseSync.exe source + build script
manifest.json       generated - defines what a synced client looks like
```

### Two different UE4SS builds, on purpose

| | build | why |
|---|---|---|
| client | 16.4 MB standalone | clients don't run the Enforcer; smaller download |
| server | 30.8 MB, from the Enforcer package | what the Enforcer was built and tested against |

They are genuinely different binaries despite the Enforcer's README implying otherwise.
**Do not cross them.**

### Client mod set

`QuickDiscard`, `ZSkiprhaxCampDeposit`, `Keybinds`, and `shared/UEHelpers`.

- `BPModLoaderMod` and `BPML_GenericFunctions` are **not shipped** — CampDeposit
  requires BPModLoaderMod disabled.
- The console and cheat-manager enablers are **not shipped** — handing players a cheat
  console would work against the server-side Enforcer.
- The client's `UE4SS-settings.ini` is **hardened**: `HookLoadMap`, `HookBeginPlay`,
  `HookEndPlay` and `HookInitGameState` are forced off. Stock UE4SS enables all four,
  and they crash Windrose 5.6.1 during world teardown. `HookUObjectProcessEvent` stays
  on because QuickDiscard's UI rewrite needs `ExecuteInGameThread`.

## Setup

**Players: download `WindroseSync.exe`, run it. That's the whole thing.**

No config file, no install, no UE4SS to fetch, no folders to create, no runtime to
install. The launcher finds Windrose through Steam, installs UE4SS and the mod set, and
starts the game. A player with a completely vanilla install ends up fully set up from
one double-click — verified: 14 files, byte-identical to the payload.

If Steam auto-detection ever fails (unusual library layout), it asks for the folder once
and remembers it in `%LOCALAPPDATA%\WindroseSync\`.

**Server admin, one time:** upload `payload/server/R5/` over the server's existing `R5/`
folder and restart. Confirm the mods started in `R5\Binaries\Win64\ue4ss\UE4SS.log`.

### Building the launcher players get

The mod source is baked into the exe at build time, which is why players have nothing to
configure:

```powershell
launcher\build.ps1 -Owner your-github-account
```

Rebuild if you move the repo. `-BaseUrl` self-hosts instead of using GitHub. An optional
`WindroseSync.config.json` beside the exe overrides the baked-in source — handy for
testing, never needed by players.

## Publishing an update

1. Drop new or updated files into `payload/client/` or `payload/server/`.
2. `tools\publish.ps1` — regenerates `manifest.json`.
3. Commit and push. Clients pick it up on their next launch.
4. If `payload/server/` changed, upload it and restart the server.

## Safety

The launcher may only write inside `R5\Binaries\Win64\ue4ss\` and
`R5\Binaries\Win64\dwmapi.dll`. Anything else — notably the ~18 GB of base game data in
`Content\Paks\` — is off limits, enforced at both plan and apply time, and asserted by
`tools\verify.ps1`. Runtime artifacts (`.log`, `.tmp`, crash dumps) inside the managed
folder are left alone so the launcher doesn't fight the game.

Downloads are written to a temp file, hash-verified, and only then moved into place, so
a failed download can never leave a half-written DLL. If the manifest can't be fetched,
the launcher **refuses to start the game** rather than connect with a mismatched mod set.

## Building the launcher

```powershell
launcher\build.ps1
```

Uses the C# compiler bundled with Windows — no .NET SDK needed. Targets .NET Framework
4.8, which is preinstalled on Windows 10/11, so players install no runtime and the exe
is ~20 KB.
