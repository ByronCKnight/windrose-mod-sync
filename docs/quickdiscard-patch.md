# Local patch: QuickDiscard relabel

We ship a **modified** copy of QuickDiscard v1.0 (Nexus mod 281). This documents the
change and how to re-apply it when the mod updates.

Pristine upstream is vendored at `vendor/QuickDiscard-1.0/main.lua.orig` for diffing.

## Why

The mod has two halves. The half that matters worked: dragging an item out of the
inventory spawns a loot bag, upstream destroys that bag as it spawns, and the item is
gone. The half that tells the player so did not — the button still read **"Drop"**.

Upstream's relabel:

```lua
for _, b in ipairs(FindAllOf("TextBlock") or {}) do
    if b:GetText():ToString():upper() == "DROP" then
        b:SetText(FText("DELETE"))
    end
end
```

registered from a single `OnVirtualSlotUpdated` hook. Three brittle spots, any one of
which leaves the label untouched:

| Spot | Problem |
|---|---|
| `== "DROP"` | Exact match. A trailing space, a newline, or a longer label ("Drop Item") misses. |
| `FindAllOf("TextBlock")` | UMG `TextBlock` only. A `RichTextBlock` label is invisible to it. |
| one hook, one pass | The scan runs when a slot updates, which is not necessarily after the label widget exists. |

The hook itself is fine — `UE4SS.log` confirms both hooks install on this build:

```
[RegisterHook] Registered native hook (1, 2) for Function /Script/R5.R5DefaultInventoryVM:OnVirtualSlotUpdated
```

so the failure is in the scan, not in getting called.

## The change

The relabel is rewritten between `[PATCH: windrose-mod-sync]` markers. The bag-destroy
half is untouched.

- **Match loosely.** Text is trimmed and lowercased, then looked up in a `LABEL_FROM`
  set (`drop`, `drop item`, `drop items`). Add a spelling there if the game ever uses a
  different one.
- **Scan `TextBlock` and `RichTextBlock`.** Both exist in this build; `CommonTextBlock`
  does not appear in the shipping exe at all, so there is no CommonUI variant to chase.
  Every UObject call is `pcall`-wrapped and `IsValid`-guarded, as in CampDeposit.
- **Rescan on a tail.** A trigger scans immediately and again at 100/250/500/1000/2000 ms,
  which covers a label built a frame or two after the hook fires.
- **Collapse the burst.** `OnVirtualSlotUpdated` fires *once per slot*, so upstream did a
  full object sweep per slot per refresh. Further triggers are now ignored until the
  in-flight tail finishes.
- **Safety net.** `SAFETY_NET_MS = 3000` runs one pass every three seconds via
  `LoopAsync`, for the case where no inventory hook fires while the button is on screen.
  A pass is a couple of milliseconds. Set it to `0` to rely on the hook alone.
- **Say so in the log.** The first three relabels log what they changed, so a label that
  stops matching after a game update is diagnosable rather than just silently wrong:

```
[QuickDiscard] loaded v1.0 (windrose patch 1)
[QuickDiscard] relabelled a TextBlock from "Drop" to "Delete"
```

Setting `DEBUG = true` additionally logs every text widget whose text contains "drop",
which is how to recover the real string if none of the `LABEL_FROM` spellings match.

## Known limitation: it relabels by text, not by widget

The scan cannot tell *which* "Drop" it found. If the inventory has a second drop path —
a context-menu entry, a hotkey row in the keybind screen — reading exactly "Drop", that
gets relabelled to "Delete" too, and those paths are **not** hooked by the bag-destroy
half, so they really do drop the item on the ground.

Upstream has the same exposure; the rewrite widens it only in that it now actually fires.
Worth an eyeball in game. Scoping it properly needs the label's owning widget, which
means a UE4SS object dump — not worth it unless a mislabel actually turns up.

## Re-applying on a mod update

1. Diff the new upstream against `vendor/QuickDiscard-1.0/main.lua.orig`.
2. Re-apply the `[PATCH]` block to the new file, keeping upstream's bag-destroy half.
3. Replace the vendored original with the new upstream and rename this doc's version.
4. Copy the patched file to `payload/client` (client-only — QuickDiscard is a UI mod and
   is not in the hostserver or server mod sets).
5. Re-run `tools\publish.ps1`.

If upstream fixes its own relabel, drop this patch entirely.
