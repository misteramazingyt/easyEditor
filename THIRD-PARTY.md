# Third-party code

## ntsc-rs
`rust/ntscbridge` links the [ntsc-rs](https://github.com/ntsc-rs/ntsc-rs) crate,
cross-compiled for iOS. Copyright the ntsc-rs authors, licensed
**MIT OR ISC OR Apache-2.0**.

## ntsc-rs presets
The presets in `aesthetic-presets/` are community ntsc-rs preset JSON, from
**Kelleesh24's NTSC-RS Presets** and **Cultra's NTSC-RS Presets Pack**. 110
preset files were rendered against the dummy frame and compared as two-second
sequences; exact duplicates and looks that could not be told apart, in stills
or in motion, were collapsed to one representative each, leaving 25. Some have
been given clearer display names than their working titles.

## Aesthetic preview frame
`aesthetic-presets/aesthetic-dummy.jpg` and the `preview-*.jpg` stills rendered
from it come from
[Na Pali Coast Kauai Hawaii](https://commons.wikimedia.org/wiki/File:Na_Pali_Coast_Kauai_Hawaii_(32406276598).jpg)
by **dronepicr**, licensed **CC BY 2.0**. Cropped to 4:3 and downscaled.

## crtemu (newpixie)
`EasyEditor/Shaders/CrtEmu.metal` is a port of the CRT fragment shader from
[crtemu.h](https://github.com/mattiasgustavsson/newpixie/blob/main/source/pixie/crtemu.h).
Copyright (c) 2016 Mattias Gustavsson, dual-licensed **MIT / public domain
(Unlicense)**. The shader body is carried over rather than reinvented; the TV
bezel texture is omitted.

## TikTok Sans
`EasyEditor/Resources/Fonts/TikTokSans.ttf` from Google Fonts, licensed
**SIL Open Font License 1.1** (`OFL-TikTokSans.txt` alongside it).
