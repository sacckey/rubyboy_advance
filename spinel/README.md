# Spinel

[Spinel](https://github.com/matz/spinel) compiles Ruby to C. `exe/rubyboy-advance` and
`exe/rubyboy-advance-bench` compile without changes into native executables, so Ruby Boy Advance
can be played and benchmarked without CRuby.

## Build Spinel

Spinel needs a C compiler, `make` and Ruby to build. These commands put it in
`../spinel`, next to this repository:

```sh
git clone https://github.com/matz/spinel.git ../spinel
make -C ../spinel deps
make -C ../spinel
```

## Play

From the repository root:

```sh
mkdir -p build/spinel
../spinel/bin/spinel -I lib exe/rubyboy-advance -o build/spinel/rubyboy-advance
build/spinel/rubyboy-advance path/to/gba_bios.bin spec/roms/hello-red/hello-red.gba
```

The executable uses SDL3 like the gem, and takes the same arguments and keys
(see [README.md](../README.md#usage)).

## Benchmark

```sh
mkdir -p build/spinel
../spinel/bin/spinel -I lib exe/rubyboy-advance-bench -o build/spinel/rubyboy-advance-bench
build/spinel/rubyboy-advance-bench \
  --bios-path path/to/gba_bios.bin --rom-path path/to/rom.gba \
  --frames 600 --warmup-frames 600 --count 3
```

The options are those of the CRuby benchmark (see [README.md](../README.md#benchmark)), and the
checksum must be the one CRuby prints for the same BIOS, ROM and frames. The executable prints
`Ruby: 4.0.7`, the Ruby version Spinel reports; record `spinel --version` instead.

## Writing code that Spinel takes

Spinel's `Integer` is 64 bits wide, and by default a result that does not fit raises a
`RangeError` where CRuby would grow the number. The emulator therefore keeps every value within
64 bits: registers wider than that are held as bytes, products are worked out by halves, and no
shift goes past the width of a word.

## Verified with

Spinel `0890056b9` (matz/spinel, 2026-10-11) on macOS (Apple Silicon).
