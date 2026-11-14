# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Eeprom do
  let(:eeprom) { described_class.new }
  let(:bytes) { [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0] }

  def send_bits(bits) = bits.each { eeprom.write_bit(it) }
  def address_bits(address, size) = (size - 1).downto(0).map { address[it] }
  def data_bits(data) = data.flat_map { |byte| 7.downto(0).map { byte[it] } }
  def to_bytes(bits) = bits.each_slice(8).map { |byte| byte.reduce(0) { |value, bit| (value << 1) | bit } }

  def write_block(address, data, size: 14)
    send_bits([1, 0] + address_bits(address, size) + data_bits(data) + [0])
  end

  def read_block(address, size: 14)
    send_bits([1, 1] + address_bits(address, size) + [0])
    Array.new(68) { eeprom.read_bit }
  end

  it 'reads 1 while it waits for a command' do
    expect(eeprom.read_bit).to eq(1)
  end

  it 'reads back a written block after four 0 bits, each byte from its top bit' do
    write_block(5, bytes)

    bits = read_block(5)

    expect([bits.first(4), to_bytes(bits.drop(4))]).to eq([[0, 0, 0, 0], bytes])
  end

  it 'reads 0xFF from blocks never written' do
    write_block(5, bytes)

    expect(to_bytes(read_block(6).drop(4))).to eq([0xFF] * 8)
  end

  it 'takes commands again after a write and after the 68 bits of a read' do
    write_block(5, bytes)
    expect(eeprom.read_bit).to eq(1)

    read_block(5)
    expect(eeprom.read_bit).to eq(1)

    write_block(6, bytes.reverse)
    expect(to_bytes(read_block(6).drop(4))).to eq(bytes.reverse)
  end

  [9, 73].each do |count|
    it "takes 6-bit addresses once a count of #{count} hints at 512 bytes" do
      eeprom.hint_size(count)

      write_block(63, bytes, size: 6)

      expect(to_bytes(read_block(63, size: 6).drop(4))).to eq(bytes)
    end
  end

  it 'keeps the first size hint and skips counts that are no command length' do
    eeprom.hint_size(68)
    eeprom.hint_size(9)
    eeprom.hint_size(17)

    write_block(63, bytes, size: 6)

    expect(to_bytes(read_block(63, size: 6).drop(4))).to eq(bytes)
  end

  it 'keeps 14-bit addresses within 8 KB' do
    write_block(0x3FFF, bytes)

    expect(to_bytes(read_block(0x3FF).drop(4))).to eq(bytes)
  end

  it 'stays waiting for a command after 00 or 01' do
    write_block(5, bytes)
    send_bits([0, 0, 0, 1])

    expect(to_bytes(read_block(5).drop(4))).to eq(bytes)
  end

  it 'ignores bits written while it sends' do
    write_block(5, bytes)
    send_bits([1, 1] + address_bits(5, 14) + [0])

    send_bits([1, 0, 1, 1])

    expect(to_bytes(Array.new(68) { eeprom.read_bit }.drop(4))).to eq(bytes)
  end

  it 'reads 0xFF and takes no writes where SRAM would be' do
    eeprom.write(0, 0x12)

    expect(eeprom.read(0)).to eq(0xFF)
  end
end
