# Server-side enforcement: investigation and outcome

**Question:** can a Windrose dedicated server detect and kick a client whose mods don't
match the server's?

**Answer: not from a Lua mod.** Recorded here so nobody repeats the experiments.

Tested against Windrose `0.10.0` / UE 5.6.1, UE4SS v3.0.1 Beta, July 2026.

---

## Why it looked possible

Windrose has no mod-aware channel in its netcode, no text chat, and the server cannot
read a client's disk. The only client→server path is the engine's own RPCs.

Scanning the shipping client binary found **60 replicated Server RPCs** — each confirmed
by a `_Validate` sibling, which means the RPC is genuinely compiled in. Several carry a
string, notably:

- `APlayerController::ServerChangeName(const FString&)`
- `APlayerController::ServerExecRPC(const FString&)`
- `APlayerController::ServerNotifyLoadedWorld(FName)`

`RegisterHook` attached to `ServerChangeName` cleanly on the server, with **no change to
the Enforcer's tuned `UE4SS-settings.ini`**. That looked like a working channel.

## Why it isn't

**UE4SS Lua does not send Server RPCs over the network. It invokes the local
`_Implementation`.**

Proven by timing. The client mod waited 30 s after spawn — well clear of connect-time
engine traffic — then sent a burst of 5 `ServerShortTimeout` calls:

| | |
|---|---|
| client reported | `BURST DONE - 5/5 sent` |
| server received at burst time (`t+209s`) | **0** |
| server received all session | 3, all at `t+179s` |

All three the server saw (`ServerVerifyViewTarget`, `ServerAcknowledgePossession`,
`ServerShortTimeout`) arrived at connect time — the engine's own traffic. Nothing the
mod sent ever left the client.

## The account corruption

The first attempt used `ServerChangeName` as the carrier, with a payload of
`\1WSYNC|<digest>|...`. Consequences:

- the server-side hook **never fired**
- the client's player name changed anyway
- the client's `R5BLAccount` RocksDB record **corrupted**, and Windrose quarantined it as
  `Broken-<id>_<version>_<timestamp>.zip` and restored from backup

One mechanism explains all three: the call executed **locally on the client**, against
persistent account state. `ServerChangeName` writes the account record — it is not a
transport, and must never be used as one.

The error appeared 0 times in logs predating the experiment and twice after, so
attribution is unambiguous.

## Rules for any future attempt

1. **Never call `ServerChangeName` from a mod.** It mutates the persistent account DB.
2. Assume any Lua RPC call runs **locally**. Verify a server-side hook actually fires
   before building on it — registration succeeding proves nothing.
3. Prefer transient RPCs (`ServerShortTimeout`, `ServerNotifyLoadedWorld`) when probing;
   they write no persistent state and caused no damage across repeated tests.
4. Back up `%LOCALAPPDATA%\R5\Saved\SaveProfiles` before any live test.

## What would actually work

A compiled **C++ UE4SS mod** on the client, invoking the RPC through the engine's real
network dispatch rather than Lua's local call. This is plausible rather than proven —
CampDeposit and the Enforcer's InventoryGuard are both C++ UE4SS mods running fine on
Windrose, so the extension point exists.

The server half is already solved: the Enforcer's `WindroseInventoryGuard` DLL consumes
kick requests dropped in `enforcer_data\kick_requests\` as JSON, so a server Lua mod can
kick without touching the C++ side. (Lua must never kick directly — per the Enforcer's
own source comments, calling the disconnect path from Lua crashes the server, observed
live 2026-05-11.)

## Useful side findings

- `HookProcessInternal = 1` is enough for `RegisterHook` to attach to these UFunctions;
  `HookUObjectProcessEvent = 1` was tried and made no difference to whether hooks fired.
  It did **not** destabilise the server, contrary to expectation.
- Windrose does **not** use SteamID server-side. It has its own backend `AccountId`
  (32 hex chars), and UE's `UniqueId` is a null-subsystem machine string like
  `NULL:Byron-PC-<hash>`. The client's *local* save profile is SteamID64-keyed, but the
  server never sees that. Player identity available to server Lua is effectively just
  `PlayerNamePrivate`.
- The four hooks the Enforcer author documents as crashing Windrose
  (`HookLoadMap`, `HookBeginPlay`, `HookEndPlay`, `HookInitGameState`) are **enabled by
  default in stock UE4SS**. Any client bundle must turn them off.
