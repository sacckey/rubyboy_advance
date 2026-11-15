# Ruby Boy Advance

A Game Boy Advance emulator written in Ruby. Work in progress.

By the author of [Ruby Boy](https://github.com/sacckey/rubyboy), a Game Boy emulator written in Ruby.

## Development

Requires Ruby 4.0 or later.

```sh
bundle install
bundle exec rake
```

`bundle exec rake` runs the specs and RuboCop.

## Usage

Running a ROM needs [SDL3](https://libsdl.org/) (on macOS: `brew install sdl3`). The specs do not.

It also needs a GBA BIOS (16 KB) dumped from your own console. No BIOS is included.

```sh
bundle exec exe/rubyboy-advance path/to/gba_bios.bin spec/roms/hello-red/hello-red.gba
```

## Benchmark

```sh
bundle exec ruby --yjit -Ilib exe/rubyboy-advance-bench \
  --bios-path path/to/gba_bios.bin --rom-path path/to/rom.gba \
  --frames 600 --warmup-frames 600 --count 3
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--bios-path PATH` | Required | 16 KB GBA BIOS dump |
| `--rom-path PATH` | Required | ROM to run |
| `--frames N` | 600 | Measured frames per trial |
| `--warmup-frames N` | 0 | Unmeasured frames before each trial |
| `--count N` | 3 | Number of trials |

Each trial starts from a fresh emulator and runs the CPU, the timers, the PPU and the APU. There is
no window, no key input, no audio device and no waiting for real time, so it does not need SDL3. It
prints the time of each trial, the FPS over all of them (measured frames divided by measured time)
and a checksum of the last frame.

To compare two versions, use the same machine, BIOS, ROM and options, with a warmup so that YJIT has
compiled the hot code. The checksum depends only on the BIOS, the ROM and the total of
`--warmup-frames` and `--frames`. If a change that should only make things faster alters it, it has
changed what is emulated.

## Spinel

[Spinel](https://github.com/matz/spinel) compiles the emulator and the benchmark into native
executables. See [spinel/README.md](spinel/README.md).

## Test ROMs

The test ROMs from [jsmolka/gba-tests](https://github.com/jsmolka/gba-tests) are not in the
repository. To run them, put the `.gba` files in `spec/roms/gba-tests`, which git ignores.

`spec/roms/hello-red/hello-red.gba` is a hand-assembled 44-byte ROM that fills the screen red in
BG mode 3; its source is `hello-red.s` next to it.

## License

MIT. Ruby Boy Advance is not affiliated with Nintendo. Game Boy Advance is a trademark of Nintendo.
