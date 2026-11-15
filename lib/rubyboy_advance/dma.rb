# frozen_string_literal: true

module RubyboyAdvance
  class Dma
    # Address bits each channel uses: DMA0 cannot read the Game Pak, and only DMA3 can write to it.
    SAD_MASKS = [0x07FF_FFFF, 0x0FFF_FFFF, 0x0FFF_FFFF, 0x0FFF_FFFF].freeze
    DAD_MASKS = [0x07FF_FFFF, 0x07FF_FFFF, 0x07FF_FFFF, 0x0FFF_FFFF].freeze
    # DMAxCNT_H bits 12-13 and the channels that start then: FIFO A asks DMA1, FIFO B asks DMA2 (NanoBoyAdvance dma.cc)
    TRIGGERS = { vblank: [1, 0..3], hblank: [2, 0..3], fifo_a: [3, [1]], fifo_b: [3, [2]] }.freeze

    # The bus comes in only for the calls that copy, so the DMA does not hold on to it
    def initialize
      @channels = [0, 0, 0, 0]
      @sads = [0, 0, 0, 0]
      @dads = [0, 0, 0, 0]
      @counts = [0, 0, 0, 0]
    end

    def read(addr)
      channel_index = (addr - 0x0B0) / 12
      shift_amount = (addr - 0x0B0) % 12

      (@channels[channel_index] >> (shift_amount * 8)) & 0xFF
    end

    def write(addr, value, bus)
      channel_index = (addr - 0x0B0) / 12
      shift_amount = (addr - 0x0B0) % 12
      before = @channels[channel_index][95]

      dma = (@channels[channel_index] & ~(0xFF << shift_amount * 8)) | (value << shift_amount * 8)
      @channels[channel_index] = dma

      return unless shift_amount == 11
      return unless before == 0 && dma[95] == 1

      @sads[channel_index] = dma & SAD_MASKS[channel_index]
      @dads[channel_index] = (dma >> 32) & DAD_MASKS[channel_index]
      @counts[channel_index] = count(dma, channel_index)
      bus.hint_eeprom_size(@counts[channel_index]) if @dads[channel_index] >= 0x0D00_0000
      transfer(channel_index, bus) if (dma >> 92) & 0b11 == 0 # cnt_h bits 12-13: start timing
    end

    def trigger(timing, bus)
      start_timing, channels = TRIGGERS.fetch(timing)
      channels.each do |channel_index|
        dma = @channels[channel_index]
        transfer(channel_index, bus) if dma[95] == 1 && (dma >> 92) & 0b11 == start_timing
      end
    end

    private

    def transfer(channel_index, bus)
      dma = @channels[channel_index]
      cnt_h = (dma >> 80) & 0xFFFF

      fifo = fifo?(dma)
      halfword = cnt_h[10] == 0 && !fifo
      step = halfword ? 2 : 4
      dad_diff = fifo ? 0 : [step, -step, 0, step][(cnt_h >> 5) & 3]
      sad_diff = [step, -step, 0, step][(cnt_h >> 7) & 3]

      sad = @sads[channel_index]
      dad = @dads[channel_index]
      sad_diff = step if (0x0800_0000...0x0E00_0000).cover?(sad) # Game Pak ROM is always read upward

      # Only the first unit is non-sequential, wherever the addresses go (NanoBoyAdvance dma.cc)
      @counts[channel_index].times do |i|
        seq = i > 0
        value = halfword ? bus.read16(sad, seq) : bus.read32(sad, seq)
        halfword ? bus.write16(dad, value, seq) : bus.write32(dad, value, seq)
        sad += sad_diff
        dad += dad_diff
      end
      bus.idle(2) # ponytail: two for each channel, not two for all that start together

      @sads[channel_index] = sad
      @dads[channel_index] = dad

      if cnt_h[9] == 1 && (cnt_h >> 12) & 3 != 0
        # A repeat counts CNT_L as it is now; the source goes on (NanoBoyAdvance dma.cc RunChannel)
        @counts[channel_index] = count(dma, channel_index)
        @dads[channel_index] = (dma >> 32) & DAD_MASKS[channel_index] if (cnt_h >> 5) & 3 == 3
      else
        @channels[channel_index] &= ~(1 << 95)
      end
    end

    # Start timing 3 feeds a sound FIFO from DMA1 or DMA2: four words to one address, whatever the registers say
    def fifo?(dma) = (dma >> 92) & 0b11 == 3

    # CNT_L, where 0 means the most the channel can move
    def count(dma, channel_index)
      return 4 if fifo?(dma)

      max = channel_index == 3 ? 0x10000 : 0x4000
      cnt_l = (dma >> 64) & (max - 1)
      cnt_l == 0 ? max : cnt_l
    end
  end
end
