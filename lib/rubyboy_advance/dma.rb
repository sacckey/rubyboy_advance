# frozen_string_literal: true

module RubyboyAdvance
  class Dma
    # Address bits each channel uses: DMA0 cannot read the Game Pak, and only DMA3 can write to it.
    SAD_MASKS = [0x07FF_FFFF, 0x0FFF_FFFF, 0x0FFF_FFFF, 0x0FFF_FFFF].freeze
    DAD_MASKS = [0x07FF_FFFF, 0x07FF_FFFF, 0x07FF_FFFF, 0x0FFF_FFFF].freeze

    def initialize(bus)
      @bus = bus
      @channels = [0, 0, 0, 0]
    end

    def read(addr)
      channel_index = (addr - 0x0B0) / 12
      shift_amount = (addr - 0x0B0) % 12

      (@channels[channel_index] >> (shift_amount * 8)) & 0xFF
    end

    def write(addr, value)
      channel_index = (addr - 0x0B0) / 12
      shift_amount = (addr - 0x0B0) % 12

      dma = (@channels[channel_index] & ~(0xFF << shift_amount * 8)) | (value << shift_amount * 8)
      @channels[channel_index] = dma

      return unless shift_amount == 11

      @channels[channel_index] &= ~(1 << 95) if write_dma(dma, channel_index)
    end

    private

    def write_dma(dma, channel_index)
      return false if dma[95] == 0

      sad = dma & SAD_MASKS[channel_index]
      dad = (dma >> 32) & DAD_MASKS[channel_index]

      max = channel_index == 3 ? 0x10000 : 0x4000
      cnt_l = (dma >> 64) & (max - 1)
      cnt = cnt_l == 0 ? max : cnt_l
      cnt_h = (dma >> 80) & 0xFFFF
      if cnt_h[12] == 0 && cnt_h[13] == 0
        halfword = cnt_h[10] == 0
        step = halfword ? 2 : 4
        dad_diff = [step, -step, 0, step][(cnt_h >> 5) & 3]
        sad_diff = [step, -step, 0, step][(cnt_h >> 7) & 3]
        sad_diff = step if (0x0800_0000...0x0E00_0000).cover?(sad) # Game Pak ROM is always read upward

        cnt.times do
          value = halfword ? @bus.read16(sad) : @bus.read32(sad)
          halfword ? @bus.write16(dad, value) : @bus.write32(dad, value)
          sad += sad_diff
          dad += dad_diff
        end

        return true
      end

      false
    end
  end
end
