# frozen_string_literal: true

require_relative 'sdl'

module RubyboyAdvance
  class Lcd
    WIDTH = 240
    HEIGHT = 160
    SCALE = 3

    def initialize
      raise SDL.get_error unless SDL.init(SDL::INIT_VIDEO)

      @window = SDL.create_window('Ruby Boy Advance', WIDTH * SCALE, HEIGHT * SCALE, 0)
      raise SDL.get_error if @window.null?

      @renderer = SDL.create_renderer(@window, nil)
      raise SDL.get_error if @renderer.null?

      @texture = SDL.create_texture(@renderer, SDL::PIXELFORMAT_XBGR1555, SDL::TEXTUREACCESS_STREAMING, WIDTH, HEIGHT)
      raise SDL.get_error if @texture.null?

      SDL.set_texture_scale_mode(@texture, SDL::SCALEMODE_NEAREST)
      @pixels = FFI::MemoryPointer.new(:uint16, WIDTH * HEIGHT)
      @event = FFI::MemoryPointer.new(:uint8, SDL::EVENT_SIZE)
    end

    def draw(buffer)
      @pixels.write_array_of_uint16(buffer)
      SDL.update_texture(@texture, nil, @pixels, WIDTH * 2)
      SDL.render_clear(@renderer)
      SDL.render_texture(@renderer, @texture, nil, nil)
      SDL.render_present(@renderer)
    end

    def window_should_close?
      while SDL.poll_event(@event)
        return true if @event.read_uint32 == SDL::EVENT_QUIT
      end

      false
    end

    def close
      SDL.destroy_texture(@texture)
      SDL.destroy_renderer(@renderer)
      SDL.destroy_window(@window)
      SDL.quit
    end
  end
end
