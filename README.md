# Redguard Trainer

A trainer for **The Elder Scrolls Adventures: Redguard** (1998) that enables windowed mode, skips intro/outro cinematics, and provides an in-game ImGui overlay with a level loader.

## The Problem

The GOG version of Redguard runs under DOSBox SVN-Daum with 3Dfx Glide passthrough. The bundled Glide wrapper (nGlide by Zeus Software, disguised as `Glide2x.dll`) forces exclusive fullscreen via Direct3D 9 — there is no config option to change this. The DOSBox `fullscreen=` setting has no effect because nGlide bypasses it entirely.

## Features

- **Windowed mode** — hooks nGlide's D3D9 `CreateDevice` to force `Windowed=TRUE`
- **Skip intro** (`--skip-intro`) — patches RGFX.EXE to bypass the intro cinematic and 3dfx splash, going straight to the main menu
- **Skip outro** (`--skip-intro`) — patches RGFX.EXE to skip the book-close animation when quitting
- **In-game overlay** — ImGui-based D3D9 overlay rendered via Present hook, toggled with backtick (`` ` ``) key
- **Level loader** — select and load any of the 28 game worlds from the overlay (writes to DOSBox emulated memory with automatic address slide detection)
- **Auto-restore** — all binary patches are reverted when DOSBox exits

## How It Works

**Windowed mode**: The trainer launches DOSBox and injects a DLL that hooks the `IDirect3D9::CreateDevice` vtable entry, flipping `D3DPRESENT_PARAMETERS.Windowed` from `FALSE` to `TRUE` when nGlide creates its D3D9 device.

```
RGFX.EXE → grSstWinOpen() → DOSBox Glide passthrough → nGlide → CreateDevice(Windowed=FALSE)
                                                                          ↓
                                                              hook flips to Windowed=TRUE
```

**Intro/outro skip**: The trainer binary-patches RGFX.EXE before DOSBox loads it, using wildcard pattern matching to find the relevant instructions regardless of LE relocation addresses. The intro skip changes a conditional jump (`JZ`) to unconditional (`JMP`) at the intro flag check. The outro skip jumps over the book-close animation calls when quitting. Both patches are restored when DOSBox exits.

**In-game overlay**: The hook DLL hooks `IDirect3DDevice9::Present` (vtable index 17) — not EndScene, because nGlide composites its Glide→D3D9 output after EndScene, overwriting anything rendered there. On first Present, it initializes Dear ImGui with D3D9 and Win32 backends, subclasses the SDL window's WndProc for input, IAT-hooks `SetCursorPos` to release the mouse when the overlay is open, and discovers DOSBox's MemBase pointer via BDA signature scanning.

**Address slide detection**: DOS/4GW may load the game's LE executable at a different base address than Ghidra assumes. The DLL scans emulated memory for a known embedded string (`"testmaps"` at Ghidra address `0x170d3a`) and calculates the runtime slide. All game memory reads/writes apply this slide automatically.

**MemBase discovery**: The DLL scans large committed memory regions for the BIOS Data Area signature (COM1 port `0x03F8` at offset `0x400` from MemBase). This reliably locates DOSBox's emulated DOS memory.

## Compatibility

Targets the **GOG version** of Redguard, which ships with DOSBox SVN-Daum and an nGlide-based `Glide2x.dll`.

## Usage

```
redguard-trainer.exe [options] <game-path>
```

| Option | Description |
|--------|-------------|
| `<game-path>` | Path to Redguard installation (contains `DOSBOX/` and `dosbox_redguard.conf`) |
| `--skip-intro` | Skip intro cinematic, 3dfx splash, and outro book-close animation |

Both `redguard-trainer.exe` and `redguard_hook.dll` must be in the same directory.

### In-Game Controls

| Key | Action |
|-----|--------|
| ` (tilde) | Toggle the overlay on/off |

### Examples

```
redguard-trainer.exe "D:\Games\GOG Galaxy\Redguard"
redguard-trainer.exe --skip-intro "D:\Games\GOG Galaxy\Redguard"
```

## Building

Requires [Zig 0.15+](https://ziglang.org/download/).

```
zig build -Doptimize=ReleaseFast
```

Outputs to `zig-out/bin/`:
- `redguard-trainer.exe` — launcher/injector (32-bit)
- `redguard_hook.dll` — D3D9 hook + ImGui overlay (32-bit)

Both binaries must be 32-bit (x86) because DOSBox SVN-Daum is a 32-bit process.

## Project Structure

```
src/main.zig        Launcher: starts DOSBox, waits for SDL window, injects hook DLL,
                    optionally patches RGFX.EXE for intro/outro skip
src/hook.zig        Hook DLL: D3D9 vtable hooks (CreateDevice, EndScene, Reset),
                    WndProc subclass, ImGui overlay, DOSBox MemBase discovery
build.zig           Build config targeting x86-windows, wires dcimgui + vendor backends
vendor/             Vendored Dear ImGui D3D9 + Win32 backends (v1.92.6) + C bridge
```

## Dependencies

- [zig-clap](https://github.com/Hejsil/zig-clap) 0.11.0 — CLI argument parsing
- [dcimgui](https://github.com/floooh/dcimgui) — Dear ImGui C bindings for Zig (core only)
- [Dear ImGui](https://github.com/ocornut/imgui) v1.92.6 backends — vendored `imgui_impl_dx9` + `imgui_impl_win32`
