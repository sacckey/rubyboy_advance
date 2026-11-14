# frozen_string_literal: true

module RubyboyAdvance
  # One bit per 16-bit access (NanoBoyAdvance eeprom.cc)
  class Eeprom
    def initialize
      @data = Array.new(0x2000, 0xFF)
      @address_bits = 14
      @size_known = false
      @reading = false
      @address = 0
      start(:command)
    end

    def hint_size(count)
      return if @size_known || ![9, 17, 73, 81].include?(count)

      @address_bits = [9, 73].include?(count) ? 6 : 14
      @size_known = true
    end

    # ponytail: no busy time after a write
    def read_bit
      return 1 unless @state == :sending

      @count += 1
      return 0 if @count <= 4

      i = @count - 5
      bit = (@data[@address + (i >> 3)] >> (7 - (i & 7))) & 1
      start(:command) if @count == 68
      bit
    end

    def write_bit(bit)
      return if @state == :sending

      @bits = (@bits << 1) | (bit & 1)
      @count += 1

      case @state
      when :command
        return unless @count == 2

        @reading = @bits == 0b11
        start(@bits[1] == 1 ? :address : :command)
      when :address
        return unless @count == @address_bits

        @address = (@bits * 8) & 0x1FFF
        start(@reading ? :end_bit : :data)
      when :data
        return unless @count == 64

        8.times { |i| @data[@address + i] = (@bits >> (56 - (i * 8))) & 0xFF }
        start(:end_bit)
      when :end_bit
        start(@reading ? :sending : :command)
      end
    end

    # No SRAM
    def read(_addr) = 0xFF

    def write(_addr, _value) = nil

    private

    def start(state)
      @state = state
      @bits = 0
      @count = 0
    end
  end
end
