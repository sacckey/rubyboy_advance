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

Spinel turns a value into a plain C integer only when it can tell its type. Where it cannot, the
value is boxed and every use of it is slow. Three things made it give up in the hot paths, and
the code avoids them:

- A type that goes round between the CPU and the bus, each taking what the other hands back. The
  `# @rbs` comments in `cpu.rb`, `bus.rb` and `interrupt.rb` state those types.
- A method that can return `nil` where a number is expected, such as a `case` without `else`.
- One array holding objects of several classes that have methods of the same name. That is why
  the APU has an instance variable for each sound channel.

`spinel --warn-widen` lists the places where Spinel gave up on a type, and `spinel --emit-rbs`
prints the types it worked out.

With the Spinel revision below, a program that uses `optparse` is refused if it also has a method
named `fetch`, so nothing here is called that.

## Verified with

Spinel `a293f9d64` (matz/spinel, 2026-11-15) on macOS (Apple Silicon).
