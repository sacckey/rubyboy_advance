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

## Test ROMs

The test ROMs from [jsmolka/gba-tests](https://github.com/jsmolka/gba-tests) are not in the
repository. To run them, put the `.gba` files in `spec/roms/gba-tests`, which git ignores.

`spec/roms/hello-red/hello-red.gba` is a hand-assembled 44-byte ROM that fills the screen red in
BG mode 3; its source is `hello-red.s` next to it.

## License

MIT. Ruby Boy Advance is not affiliated with Nintendo. Game Boy Advance is a trademark of Nintendo.
