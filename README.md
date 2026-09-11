# idh-autofish

Auto-fishing for **Indo Hangout** (`PlaceId 9788848685`). Plays the reeling minigame for real (holds/releases Space to track the bar), plus remote auto-sell and a control panel UI.

## Use (executor)

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/jinjoee/idh-autofish/main/indo-autofish.luau"))()
```

Stand at your fishing spot with a rod, run it, open the panel:
- **AutoFish ON/OFF**, **AutoSell ON/OFF**
- **Sell filter dropdown** (weight filters double as rarity: light = common)
- **Sell Now** + bag-count threshold (`-`/`+`, default sells at 15 fish)

## Notes

- Human-like: real input events, random pauses, breaks every 25 fish.
- No anti-cheat bypass: catch timing is always genuine skilled-play timing.
- Settings reset on rejoin/re-execute (session state only).
