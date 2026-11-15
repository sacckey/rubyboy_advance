# frozen_string_literal: true

module RubyboyAdvance
  class Dma
    # Address bits each channel uses: DMA0 cannot read the Game Pak, and only DMA3 can write to it.
    SAD_MASKS = [0x07FF_FFFF, 0x0FFF_FFFF, 0x0FFF_FFFF, 0x0FFF_FFFF].freeze
    DAD_MASKS = [0x07FF_FFFF, 0x07FF_FFFF, 0x07FF_FFFF, 0x0FFF_FFFF].freeze

    # The bus comes in only for the calls that copy, so the DMA does not hold on to it
    def initialize
      @io = Array.new(48, 0) # twelve bytes a channel: SAD, DAD, CNT_L, CNT_H
      @sads = [0, 0, 0, 0]
      @dads = [0, 0, 0, 0]
      @counts = [0, 0, 0, 0]
    end

    def read(addr)
      @io[addr - 0x0B0]
    end

    def write(addr, value, bus)
      offset = addr - 0x0B0
      channel_index = offset / 12
      before = cnt_h(channel_index)[15]
      @io[offset] = value

      return unless offset % 12 == 11
      return unless before == 0 && cnt_h(channel_index)[15] == 1

      @sads[channel_index] = register(channel_index, 0, 4) & SAD_MASKS[channel_index]
      @dads[channel_index] = register(channel_index, 4, 4) & DAD_MASKS[channel_index]
      @counts[channel_index] = count(channel_index)
      bus.hint_eeprom_size(@counts[channel_index]) if @dads[channel_index] >= 0x0D00_0000
      transfer(channel_index, bus) if (cnt_h(channel_index) >> 12) & 0b11 == 0
    end

    # Start timings are DMAxCNT_H bits 12-13. FIFO A asks DMA1 and FIFO B asks DMA2 (NanoBoyAdvance dma.cc)
    def trigger(timing, bus)
      case timing
      when :vblank then 4.times { |channel_index| start(channel_index, 1, bus) }
      when :hblank then 4.times { |channel_index| start(channel_index, 2, bus) }
      when :fifo_a then start(1, 3, bus)
      when :fifo_b then start(2, 3, bus)
      end
    end

    private

    # A register of a channel, from its bytes: SAD is at 0, DAD at 4, CNT_L at 8, CNT_H at 10
    def register(channel_index, offset, size)
      base = (channel_index * 12) + offset
      value = 0
      size.times { |i| value |= @io[base + i] << (i * 8) }
      value
    end

    def cnt_h(channel_index)
      register(channel_index, 10, 2)
    end

    def start(channel_index, start_timing, bus)
      cnt_h = cnt_h(channel_index)
      transfer(channel_index, bus) if cnt_h[15] == 1 && (cnt_h >> 12) & 0b11 == start_timing
    end

    def transfer(channel_index, bus)
      cnt_h = cnt_h(channel_index)

      fifo = fifo?(cnt_h)
      halfword = cnt_h[10] == 0 && !fifo
      step = halfword ? 2 : 4
      dad_diff = fifo ? 0 : [step, -step, 0, step][(cnt_h >> 5) & 3]
      sad_diff = [step, -step, 0, step][(cnt_h >> 7) & 3]

      sad = @sads[channel_index]
      dad = @dads[channel_index]
      sad_diff = step if sad >= 0x0800_0000 && sad < 0x0E00_0000 # Game Pak ROM is always read upward

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
        @counts[channel_index] = count(channel_index)
        @dads[channel_index] = register(channel_index, 4, 4) & DAD_MASKS[channel_index] if (cnt_h >> 5) & 3 == 3
      else
        @io[(channel_index * 12) + 11] &= 0x7F
      end
    end

    # Start timing 3 feeds a sound FIFO from DMA1 or DMA2: four words to one address, whatever the registers say
    def fifo?(cnt_h)
      (cnt_h >> 12) & 0b11 == 3
    end

    # CNT_L, where 0 means the most the channel can move
    def count(channel_index)
      return 4 if fifo?(cnt_h(channel_index))

      max = channel_index == 3 ? 0x10000 : 0x4000
      cnt_l = register(channel_index, 8, 2) & (max - 1)
      cnt_l == 0 ? max : cnt_l
    end
  end
end
