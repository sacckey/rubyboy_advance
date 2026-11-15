# frozen_string_literal: true

require_relative 'sdl'

module RubyboyAdvance
  class Audio
    SAMPLE_RATE = 32768 # the Apu makes one sample every 512 cycles
    MAX_QUEUED = 4096 # bytes, about 30 ms

    def initialize
      raise SDL.get_error unless SDL.init(SDL::INIT_AUDIO)

      spec = FFI::MemoryPointer.new(:int32, 3)
      spec.write_array_of_int32([SDL::AUDIO_S16LE, 2, SAMPLE_RATE])
      @stream = SDL.open_audio_device_stream(SDL::AUDIO_DEVICE_DEFAULT_PLAYBACK, spec, nil, nil)
      raise SDL.get_error if @stream.null?

      SDL.resume_audio_stream_device(@stream)
    end

    # Waits while enough is left to play, which keeps the emulator from running ahead of real time
    def queue(samples)
      sleep(0.001) while SDL.get_audio_stream_queued(@stream) > MAX_QUEUED
      SDL.put_audio_stream_data(@stream, samples.pack('s<*'), samples.size * 2)
    end
  end
end
