# Third-party code

## ntsc-rs
`rust/ntscbridge` links the [ntsc-rs](https://github.com/ntsc-rs/ntsc-rs) crate,
cross-compiled for iOS. Copyright the ntsc-rs authors, licensed
**MIT OR ISC OR Apache-2.0**. The bundled presets in `aesthetic-presets/` are
ntsc-rs preset JSON from the Kelleesh24 preset collection.

## crtemu (newpixie)
`EasyEditor/Shaders/CrtEmu.metal` is a port of the CRT fragment shader from
[crtemu.h](https://github.com/mattiasgustavsson/newpixie/blob/main/source/pixie/crtemu.h).
Copyright (c) 2016 Mattias Gustavsson, dual-licensed **MIT / public domain
(Unlicense)**. The shader body is carried over rather than reinvented; the TV
bezel texture is omitted.

## TikTok Sans
`EasyEditor/Resources/Fonts/TikTokSans.ttf` from Google Fonts, licensed
**SIL Open Font License 1.1** (`OFL-TikTokSans.txt` alongside it).
