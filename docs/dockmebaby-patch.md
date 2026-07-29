# Local patch: DockMeBaby keybinds and save file

We ship a **modified** copy of DockMeBaby v2.0.0. This documents the changes and how to
re-apply them when the mod updates.

Pristine upstream is vendored at `vendor/DockMeBaby-2.0.0/main.lua.orig` for diffing.

## What the mod does

Two actions. `setdock` finds the ship nearest the player and records its position and
yaw under that player's name and world. `dock` reads those records back and teleports
every saved ship home, along with anyone standing on one — and refuses unless the player
is within 25,000 units (~250 m) of a Camp.

## Change 1: keybinds instead of console commands

Upstream registered `RegisterConsoleCommandHandler("setdock")` and `("dock")`. That
cannot work here. This repo deliberately ships **no** `ConsoleEnablerMod` and sets
`ConsoleEnabled = 0` / `GuiConsoleEnabled = 0` in `UE4SS-settings.ini`, because handing
players a cheat console would work directly against the server-side Enforcer. The
commands registered fine and no player could ever type them.

So the two handler bodies became plain functions, bound to keys:

| Key | Action |
|---|---|
| `.` (`Key.OEM_PERIOD`) | `setdock` — save the nearest ship's spot |
| `P` (`Key.P`) | `dock` — recall every saved ship |

Rebind at the top of the patch block:

```lua
local DockKeybinds = {
    SetDock = { Key = Key.OEM_PERIOD, ModifierKeys = {} },
    Dock    = { Key = Key.P,          ModifierKeys = {} },
}
```

Valid key names are the list at the bottom of `ue4ss\Mods\Keybinds\Scripts\main.lua`.
Numpad `.` is `DECIMAL`, not `OEM_PERIOD`.

Three things the keybind path needs that the console path got for free:

- **Game thread.** A console handler already ran on it; a UE4SS keybind callback does
  not. Both the guard and the action are wrapped in `ExecuteInGameThread`, same as
  QuickDiscard's widget scan. The ping tail inside `DispatchCommandSequence` keeps
  upstream's threading, unchanged.
- **A cooldown.** `KEY_COOLDOWN_SECONDS = 1.0`. UE4SS keybinds fire regardless of what
  the game thinks the key means, so a stray `.` overwriting a saved dock is cheap to
  guard against.
- **A local-player check.** See below.

### Bare keys fire while you are typing

This is the real cost of the change, and it is worth knowing about. UE4SS polls the
keyboard itself, so `.` and `P` trigger even with a text field focused — naming a ship,
for instance. `dock` is harmless to fire by accident; `setdock` silently overwrites that
ship's saved spot. If it becomes a nuisance, add a modifier:

```lua
SetDock = { Key = Key.OEM_PERIOD, ModifierKeys = { ModifierKey.CONTROL } },
```

## Change 2: the save file is renamed so a sync cannot eat it

Upstream wrote `ue4ss/Mods/DockMeBaby/DockMeBaby_SaveData.lua`. That is inside the
launcher's managed tree, and anything in there the manifest doesn't list is **stale** and
gets deleted — so every launch would have wiped the player's docks.

Two halves to the fix:

- the mod writes `ue4ss/Mods/DockMeBaby/DockMeBaby.savedata.lua`
- `.savedata.lua` is on the launcher's `RuntimeSuffixes` preserve list, alongside `.log`
  and `.dmp`

Same reasoning as logs: it lives in our folder but it is not ours to manage. The suffix
is a general opt-in, so any future mod with per-player data can use it rather than
needing its own carve-out. `tools\verify.ps1` asserts a `.savedata.lua` file survives a
sync.

The mod does not create the directory — Lua can't — but `Scripts/` and `enabled.txt`
ship into it, so it always exists.

## Where it's installed

Same three targets as CampDepositReloaded, and the same single file to all of them:

| Target | Which half matters |
|---|---|
| `client` | keybinds, and the whole mod in singleplayer (local authority) |
| `hostserver` | the server hook — Host Game's authority lives in that process |
| `server` | the server hook, on the dedicated server |

The keybinds are registered in all three but **no-op** where there is no local player.
`HasLocalPlayer()` asks whether a game viewport exists — UEHelpers documents that as the
thing a server doesn't have, and it is a property read rather than a UFunction call, so
it answers reliably. It **fails closed**: no viewport, no keypress. A dedicated server's
console window must never be able to teleport somebody's ship.

`FindFirstOf("PlayerController")` would be the obvious probe and is the wrong one — on a
server it returns a connected *player's* controller quite happily.

This also added `shared/UEHelpers/UEHelpers.lua` to the `hostserver` and `server`
payloads; DockMeBaby is the first mod on either that requires it.

## Two open risks in upstream's netcode

Neither is caused by this patch, and neither is fixed by it. Both need a live test.

### 1. The client→server channel may not exist

Away from local authority, upstream signals the server by calling
`pc:ServerCheckClientPossession()` a set number of times — 5 for `setdock`, 3 for
`dock` — and a server-side `RegisterHook` counts them inside a 2-second window.

[docs/enforcement-findings.md](enforcement-findings.md) records the opposite result for
this exact mechanism: **UE4SS Lua does not send Server RPCs over the network**, it runs
the local `_Implementation`. A 5-call burst of `ServerShortTimeout` was sent and the
server received none of it.

If that holds for `ServerCheckClientPossession` too, then:

| Playing | Works? |
|---|---|
| Singleplayer | **yes** — `HasAuthority()` is true, logic runs locally |
| Host Game | no — the visible process is a client of the server process |
| Dedicated server | no |

Shipped to all three targets anyway: the cost is ~30 KB and the server half is either
already correct or already in place for whenever a C++ RPC bridge lands. Watch
`UE4SS.log` on the server for `Server intercepted Dock sequence` to find out.

`ServerCheckClientPossession` is at least a *safe* carrier to probe with, per that
document's own rules — it is transient, unlike `ServerChangeName`, which corrupted an
account database when it ran locally.

### 2. The engine sends that RPC too

The hook counts every `ServerCheckClientPossession` the server sees, including the
engine's own. The client sends it whenever `AcknowledgedPawn` diverges from its pawn —
respawns, and **possession changes**. In Windrose players possess ships when they take
the helm, so that fires often. Three of them inside two seconds is a spurious `dock`:
somebody's fleet teleports home unasked.

Upstream's exact-count matching (3, and 5) is all that stands between normal play and a
false trigger. Raising the counts to values the engine won't naturally emit would help,
but it is a change to the netcode contract on both sides at once and pointless until
risk 1 is settled — so it is deliberately **not** done here.

## Re-applying on a mod update

1. Diff the new upstream against `vendor/DockMeBaby-2.0.0/main.lua.orig`.
2. Re-apply the three `[PATCH]` blocks: `GetSaveFilePath`, the keybind section that
   replaces the console handlers, and the startup log line.
3. Replace the vendored original with the new upstream and rename this doc's version.
4. Copy the patched file to all three payload targets (`client`, `hostserver`, `server`).
5. Re-run `tools\publish.ps1`.

If upstream ever adds its own keybinds, keep the save-file rename and drop the rest.
