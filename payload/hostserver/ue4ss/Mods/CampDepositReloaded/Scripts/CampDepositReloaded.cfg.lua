-- CampDepositReloaded settings, server-authoritative.
--
-- Kept in the repo so the server's behaviour is version-controlled rather than
-- living only on the box. Values carried over from the ZSkiprhaxCampDeposit
-- install this replaces, so deposit range is unchanged for players.
--
-- Only keys the mod already defines are read, and only if the type matches -
-- anything else here is ignored.

return {
    enabled = true,

    -- Deposit reaches chests within this many metres of the player.
    radiusMeters = 48.0,

    -- Cap on chests touched per deposit. Guards against a huge camp turning one
    -- key press into a long server-side loop.
    maxAttempts = 16,

    -- Logs a line per deposit to UE4SS.log. Useful while bedding the mod in;
    -- set false once it is proven if the log gets noisy.
    runtimeLogging = true,

    -- Verbose per-deposit tracing. Only for diagnosing a silent failure.
    debug = false,
}
