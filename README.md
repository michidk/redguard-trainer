# Redguard Trainer

A windowed-mode trainer for **The Elder Scrolls Adventures: Redguard** (1998).

## The Problem

The GOG version of Redguard runs under DOSBox SVN-Daum with 3Dfx Glide passthrough. The bundled Glide wrapper (nGlide by Zeus Software, disguised as `Glide2x.dll`) forces exclusive fullscreen via Direct3D 9 — there is no config option to change this. The DOSBox `fullscreen=` setting has no effect because nGlide bypasses it entirely.

## How It Works

The trainer launches DOSBox and injects a small DLL into the process before the game initializes Glide. The DLL hooks the `IDirect3D9::CreateDevice` vtable entry and flips `D3DPRESENT_PARAMETERS.Windowed` from `FALSE` to `TRUE` when nGlide creates its D3D9 device. The game runs windowed with full Glide rendering at native speed.

```
RGFX.EXE → grSstWinOpen() → DOSBox Glide passthrough → nGlide → CreateDevice(Windowed=FALSE)
                                                                          ↓
                                                              hook flips to Windowed=TRUE
```

## Compatibility

Targets the **GOG version** of Redguard, which ships with DOSBox SVN-Daum and an nGlide-based `Glide2x.dll`.

## Usage

```
redguard-trainer.exe "D:\Games\GOG Galaxy\Redguard"
```

The argument is the path to your Redguard installation directory (the folder containing `DOSBOX/` and `dosbox_redguard.conf`).

Both `redguard-trainer.exe` and `redguard_hook.dll` must be in the same directory.

## Building

Requires [Zig 0.15+](https://ziglang.org/download/).

```
zig build -Doptimize=ReleaseFast
```

Outputs to `zig-out/bin/`:
- `redguard-trainer.exe` — launcher/injector (32-bit)
- `redguard_hook.dll` — D3D9 vtable hook (32-bit)

Both binaries must be 32-bit (x86) because DOSBox SVN-Daum is a 32-bit process.

## Project Structure

```
src/main.zig   Launcher: starts DOSBox, waits for SDL window, injects hook DLL
src/hook.zig   Hook DLL: polls for d3d9.dll, hooks IDirect3D9::CreateDevice vtable
build.zig      Build config targeting x86-windows
```
