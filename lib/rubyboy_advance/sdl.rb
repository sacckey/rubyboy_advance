# frozen_string_literal: true

require 'ffi'

module RubyboyAdvance
  module SDL
    extend FFI::Library

    ffi_lib 'SDL3'

    INIT_VIDEO = 0x20
    PIXELFORMAT_XBGR1555 = 0x15530F02
    TEXTUREACCESS_STREAMING = 1
    SCALEMODE_NEAREST = 0
    EVENT_QUIT = 0x100
    EVENT_SIZE = 128

    attach_function :init, :SDL_Init, [:uint32], :bool
    attach_function :quit, :SDL_Quit, [], :void
    attach_function :get_error, :SDL_GetError, [], :string
    attach_function :create_window, :SDL_CreateWindow, %i[string int int uint64], :pointer
    attach_function :destroy_window, :SDL_DestroyWindow, [:pointer], :void
    attach_function :create_renderer, :SDL_CreateRenderer, %i[pointer string], :pointer
    attach_function :destroy_renderer, :SDL_DestroyRenderer, [:pointer], :void
    attach_function :create_texture, :SDL_CreateTexture, %i[pointer uint32 int int int], :pointer
    attach_function :destroy_texture, :SDL_DestroyTexture, [:pointer], :void
    attach_function :set_texture_scale_mode, :SDL_SetTextureScaleMode, %i[pointer int], :bool
    attach_function :update_texture, :SDL_UpdateTexture, %i[pointer pointer pointer int], :bool
    attach_function :render_clear, :SDL_RenderClear, [:pointer], :bool
    attach_function :render_texture, :SDL_RenderTexture, %i[pointer pointer pointer pointer], :bool
    attach_function :render_present, :SDL_RenderPresent, [:pointer], :bool
    attach_function :poll_event, :SDL_PollEvent, [:pointer], :bool
  end
end
