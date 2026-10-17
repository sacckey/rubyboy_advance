# frozen_string_literal: true

module RubyboyAdvance
  class Bus
    def initialize(rom)
      @ewram = Array.new(0x40000, 0)
      @iwram = Array.new(0x8000, 0)
      @ioram = Array.new(0x400, 0)
      @palram = Array.new(0x400, 0)
      @vram = Array.new(0x18000, 0)
      @oam = Array.new(0x400, 0)
      @rom = rom
      @cartram = Array.new(0x10000, 0)
    end

    def read(addr)
      case addr >> 24
      when 0x02 then return @ewram[addr & 0x3FFFF]
      when 0x03 then return @iwram[addr & 0x7FFF]
      when 0x04 then return @ioram[addr & 0x3FF]
      when 0x05 then return @palram[addr & 0x3FF]
      when 0x06
        case addr[16]
        when 0 then return @vram[addr & 0xFFFF]
        when 1 then return @vram[addr & 0x17FFF]
        end
      when 0x07 then return @oam[addr & 0x3FF]
      when 0x08, 0x09 then return @rom[addr & 0x1FFFFFF] || 0
      when 0x0E then return @cartram[addr & 0xFFFF]
      end

      0xff
    end

    def write(addr, value)
      case addr >> 24
      when 0x02 then @ewram[addr & 0x3FFFF] = value
      when 0x03 then @iwram[addr & 0x7FFF] = value
      when 0x04 then @ioram[addr & 0x3FF] = value
      when 0x05 then @palram[addr & 0x3FF] = value
      when 0x06
        case addr[16]
        when 0 then @vram[addr & 0xFFFF] = value
        when 1 then @vram[addr & 0x17FFF] = value
        end
      when 0x07 then @oam[addr & 0x3FF] = value
      when 0x0E then @cartram[addr & 0xFFFF] = value
      end

      nil
    end

    def read16(addr)
      read(addr) + (read(addr + 1) << 8)
    end

    def write16(addr, value)
      write(addr, value & 0xFF)
      write(addr + 1, (value >> 8) & 0xFF)
    end

    def read32(addr)
      read16(addr) + (read16(addr + 2) << 16)
    end

    def write32(addr, value)
      write16(addr, value & 0xFFFF)
      write16(addr + 2, (value >> 16) & 0xFFFF)
    end
  end
end
