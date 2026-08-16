# EasyEditor desktop library server

Serves your local picture library (`E:\02 pictures`) and its semanticSearch
CLIP index to the EasyEditor iOS app over Tailscale.

## Run it

Uses the same Python environment as semanticSearch (it imports that project
directly — no code duplication, same DB/index):

```powershell
cd "d:\Inbox\00 Now\202607280921 - easyEditor\desktop-server"
python server.py --library "E:/02 pictures" `
  --search-code "D:/Inbox/00 Now/202606041618 - pluginDev/semanticSearch" `
  --port 8787 --token pick-a-secret
```

**My Quotes** (`/myquotes/*`) is on by default too, pointed at
`C:/Users/Shae/Documents/GitHub/misteramazing/_quotes` — override with
`--my-quotes <path>`, disable with `--my-quotes ""`. Card *styles* are
discovered from disk: `cards/<qid>.jpg` is style `default`, and either
`cards/<style>/<qid>.jpg` or `cards/<qid>__<style>.jpg` adds named styles.
Shoot the other designs from `tools/card_template.py` into one of those
layouts and the app starts shuffling between them with no server change.

The quote browser (`/quote/*`) is on by default, pointed at
`D:/Inbox/00 Now/202607270424 - greatBooks/quotes` — override with
`--quotes <path>` or disable with `--quotes ""`. Natural-language quote
queries need `GEMINI_API_KEY` in the environment (same key nlq.py uses);
without it the server falls back to keyword search.

- `/search` needs the FAISS index semanticSearch's `index.py` builds; if it's
  missing the server still runs with browse/thumbnails only.
- The CLIP model loads lazily on the first search (few seconds).
- `--token` is optional but recommended; enter the same value in the app.

## Connect from the phone

Both devices must be on your tailnet.

**Option A — plain HTTP (simplest):**
Find your desktop's Tailscale IP (`tailscale ip -4`, a `100.x.y.z` address) and
enter `http://100.x.y.z:8787` in EasyEditor → Settings. The app ships with an
ATS exception so plain HTTP works; traffic is still encrypted end-to-end by
Tailscale (WireGuard).

**Option B — HTTPS via tailscale serve:**
```powershell
tailscale serve --bg 8787
```
gives you `https://<machine>.<tailnet>.ts.net` with a valid certificate; enter
that URL in the app instead.

## Endpoints

| Route | Params | Returns |
|---|---|---|
| `/health` | — | status + index size |
| `/browse` | `path` (optional) | subfolders + images of a folder |
| `/search` | `q`, `k`, `folder`, `bg` (`solid`/`transparent`), `color` (hex) | semantic results via semanticSearch's SearchService, filtered |
| `/myquotes/sections` `/myquotes/search` `/myquotes/image` | `q`, `section`, `qid`, `style` | the misteramazing `_quotes` cards, style randomized per search |
| `/thumb` | `path` | cached 384px JPEG |
| `/file` | `path` | original file (odd formats transcoded to JPEG) |

All routes accept `?token=` (or `X-Auth-Token`) when a token is set. Paths are
restricted to the library root plus semanticSearch's configured folders.

## Auto-start on login (optional)

```powershell
schtasks /create /tn EasyEditorLibrary /sc onlogon /tr `
  "pythonw \"d:\...\desktop-server\server.py\" --library \"E:/02 pictures\" --search-code \"D:/...semanticSearch\" --port 8787 --token pick-a-secret"
```
