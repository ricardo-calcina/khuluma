# Name check (roadmap P0a)

Status: **open.** "Lowkey" is ruled out as the public name (2026-10-16). No replacement chosen yet: decide once the P0b tidy-up is done, before phase 2 puts the name into the repo, cask, bundle and TCC grants. Until then "Lowkey" stays the working name in code and docs. Nothing has been renamed.

Pinned, not checked yet: **DTNSND** ("dictate 'n' send"), 2026-10-16.

## Why not Lowkey
1313Labs Ltd (London) holds LOWKEY as a word mark covering software in all three markets that matter:
- UK **UK00003672761**, registered 2021-11-19, classes 9, 35, 38, 41, 42, 45. Class 9 includes "mobile apps" and "computer software"; class 42 includes SaaS ([tm-uk-lowkey]).
- US **7813710** (serial 97411847), registered 2025-06-03, classes 9, 35, 38, 41, 42 ([tm-us-lowkey]; also on USPTO tmsearch).
- EU **018610302**, registered 2022-05-12, classes 9, 35, 38, 41, 42, 45 (mirror only, [tm-eu-lowkey]).

Other live US LOWKEY marks: LOWKEY, Inc. (gaming-clip software, 9/42, serial 90354659) and Lowkey Enterprises (health/messaging apps, 9/42/44, pending, serial 50059333). Respellings (Lowkee, Lowki, LowKey) sound the same, so the same marks apply; "Lowkey Dictation" only adds a descriptive word. The App Store has several Lowkey apps already, lowkey.app is for resale, and "lowkey" as a search term is all slang and the UK rapper.

## Candidates checked (2026-10-16)
Checks per name: `ricardo-nth/<name>` on GitHub, `brew search` (formula and cask), the iTunes Search API (Mac and iOS, GB store), GitHub repos describing voice or dictation, RDAP for `.app`/`.com`/`.dev` plus `get…`/`use…` fallbacks, USPTO tmsearch (searched directly, by typing in the search box: URL queries don't run), UKIPO and EUIPO through mirrors (trademarkelite, trademarkia), and a web search for existing products.

| Name | Result | Why |
| --- | --- | --- |
| Undersay | Clear on paper; not chosen | No marks or products found; `.app`/`.dev` free. Didn't resonate |
| Tacy | Some risk; not chosen | Thomas Cook India's TACY travel assistant; TACIT silent-speech marks (UK/EU 9/42) nearby. Didn't resonate |
| Kwiet | Some risk | Sounds like QUIET, which has EU/Madrid software marks (9/38/42) |
| Hushi | Some risk | Hushi AI-captions iPhone app (listing gone); Hush Touch Mac dictation nearby; "nurse" in Mandarin |
| Lowtalk | Some risk | No marks, but shares LOW with the 1313Labs software mark |
| SaySend, Saysnd | Avoid | saysend.ai (voice business software), saysend.app (LinkedIn writer) |
| Sayzo | Avoid | UK SAYSO marks (voice chat 38, news app 9); SayZo AI video software |
| Hushkey | Avoid | EU Hushkey (9, live), UK HUSHKEYS (9/42, live) |
| Voxlet | Avoid | US VOXLETS (voice software, 9); Voxlit Mac dictation |
| Vocli | Avoid | voCLI offline voice assistant (PyPI) |
| Sotti | Avoid | EU SOTI software marks (42); Sotto Audio Mac mic app |
| Quietype, Holdtalk, HushType, Saydown, Halfvoice, Murmo, KeySay, Dictly, Sotto | Avoid | Each is already a local or Mac dictation app or repo |
| Undervoice, Murmly, Sayo, Tovo, Voko, VoiceKey, Offhand, Natter, Murmel, Aside, Parley | Avoid | Existing voice-notes, speech-to-text or speaking apps |
| Hush, Tuck, Wren, Psst, Kiro, Lowdown | Avoid | Homebrew name taken |

## What we learned
- Local Mac dictation is crowded: anything that hints at speech or quiet is usually already a dictation app, often one built in 2026.
- A respelling doesn't escape a mark: trademark confusion is judged on sound, so Kwiet = QUIET and Lowki = LOWKEY.
- Short `.app`/`.com`/`.dev` names, even coined ones, are nearly all registered. Plan on a `get…` or `use…` `.app` domain if a domain is wanted at all.
- UKIPO, EUIPO (TMview) and WIPO block automated searches. Before committing to a name, search the official UK and EU registers by hand.
- "Some risk" is normal for a free GitHub/Homebrew app. Lowkey was a hard no because an exact live mark covers "computer software" in the UK, EU and US.

## Sources
- [tm-uk-lowkey] Trademarkia, LOWKEY UK00003672761 (1313Labs Ltd)
- [tm-us-lowkey] Trademarkia, LOWKEY serial 97411847 / reg. 7813710 (1313Labs Ltd); USPTO trademark search (tmsearch.uspto.gov)
- [tm-eu-lowkey] TrademarkElite, LOWKEY EUTM 018610302 (1313Labs Ltd)
- iTunes Search API (itunes.apple.com/search), RDAP (rdap.org), GitHub search, Homebrew, checked 2026-10-15/16
