# Local patch: CampDepositReloaded authority guard

We ship a **modified** copy of CampDepositReloaded v0.1.0. This documents the change
and how to re-apply it when the mod updates.

Pristine upstream is vendored at `vendor/CampDepositReloaded-0.1.0/main.lua.orig`
for diffing.

## Why

Upstream is explicit:

> Install wherever the game's authoritative server logic actually runs - not on clients.

That's install-time advice, and it works when there's one answer. There isn't:

| Situation | Where authority lives |
|---|---|
| Connected to a dedicated server | the dedicated server |
| Singleplayer | the game process itself |
| Host Game | a separate `WindroseServer` process under `R5\Builds\WindowsServer` |

The launcher can't know in advance which a player will do, so it installs to the game
folder (for singleplayer) **and** the bundled server folder (for Host Game). That means
the copy in the game folder is also loaded when the player connects to a dedicated
server — exactly the case upstream says to avoid.

Unguarded, `runMultipass` would then run on a client and briefly rewrite the interact
component's owner pointer via `writeCompProbe`. Those writes achieve nothing
authoritative, but they leave a window where the game could read a pointer we lied
about. Not worth risking on every player's machine.

## The change

One function plus a three-line early return in `runMultipass`, both wrapped in
`[PATCH: windrose-mod-sync]` markers.

```lua
if not hasAuthority(avatar) then
    trace("not the authoritative process for this deposit, skipping")
    return
end
```

`hasAuthority` tries `actor:HasAuthority()`, falls back to `GetNetMode() ~= 3`
(`NM_Client`), and **fails closed** if neither works — refusing to poke memory on a
guess. It logs its verdict once per session so a silently-disabled mod is diagnosable
from the log rather than looking simply broken:

```
[CampDepositReloaded] authority probe: HasAuthority -> true
```

Behaviour after the patch:

| Process | Authority | Multipass |
|---|---|---|
| Dedicated server | yes | runs |
| Singleplayer | yes | runs |
| Host Game server process | yes | runs |
| Client connected to a server | no | **no-op** |

Note the guard is a no-op on a real dedicated server, so the same patched file is
shipped to all three locations rather than maintaining variants.

## Re-applying on a mod update

1. Diff the new upstream against `vendor/CampDepositReloaded-0.1.0/main.lua.orig`.
2. Re-apply both `[PATCH]` blocks to the new file.
3. Replace the vendored original with the new upstream and rename this doc's version.
4. Copy the patched file to all three payload targets (`client`, `hostserver`, `server`).
5. Re-run `tools\publish.ps1`.

If upstream ever adds its own authority check, drop this patch entirely.
