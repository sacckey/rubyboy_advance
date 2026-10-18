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

```sh
bundle exec exe/rubyboy-advance spec/roms/hello-red/hello-red.gba
```

## Test ROMs

`spec/roms/gba-tests` contains `arm.gba` and `thumb.gba` from
[jsmolka/gba-tests](https://github.com/jsmolka/gba-tests) (MIT License, see its `LICENSE`).

`spec/roms/hello-red/hello-red.gba` is a hand-assembled 44-byte ROM that fills the screen red in
BG mode 3; its source is `hello-red.s` next to it.

## License

MIT. Ruby Boy Advance is not affiliated with Nintendo. Game Boy Advance is a trademark of Nintendo.
