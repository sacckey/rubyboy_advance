# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'tmpdir'

RSpec.describe 'rubyboy-advance-bench' do
  let(:root) { File.expand_path('../..', __dir__) }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  # hello-red never enters the BIOS, so zeros stand in for one
  def zeros(size) = File.join(@dir, "#{size}.bin").tap { File.binwrite(it, "\0" * size) }

  # :bios and :rom stand for the paths of a stand-in BIOS and of hello-red
  def bench(*args)
    paths = { bios: zeros(0x4000), rom: 'spec/roms/hello-red/hello-red.gba' }
    Open3.capture3(RbConfig.ruby, '-Ilib', 'exe/rubyboy-advance-bench', *args.map { paths.fetch(it, it) }, chdir: root)
  end

  it 'runs the warmup and the measured frames of each trial, and prints the times, the FPS and the checksum of the last frame' do
    stdout, stderr, status = bench('--bios-path', :bios, '--rom-path', :rom, '--count', '2', '--frames', '3', '--warmup-frames', '3')
    red = Array.new(240 * 160, 0x1F).reduce(0) { |hash, pixel| ((hash * 31) + pixel) & 0xFFFF_FFFF } # all red by frame 6

    expect(status.success?).to be(true), stderr
    expect(stdout).to match(/\ARuby: \S+\nYJIT: (true|false)\n1: [\d.e-]+ sec\n2: [\d.e-]+ sec\nFPS: [\d.]+\nChecksum: #{red}\n\z/)
    first, second, fps = stdout.scan(/^(?:\d|FPS): (\S+)/).flatten.map(&:to_f)
    expect(fps).to eq(3 * 2 / (first + second))
  end

  it 'does not count the warmup frames as measured ones' do
    stdout, = bench('--bios-path', :bios, '--rom-path', :rom, '--count', '1', '--frames', '3')

    expect(stdout).to match(/^Checksum: \d+$/)
    expect(stdout).not_to include('Checksum: 4063666176') # three frames in, the screen is not red all over
  end

  {
    'no arguments' => [],
    'no BIOS' => ['--rom-path', :rom],
    'no ROM' => ['--bios-path', :bios],
    'the paths without their options' => %i[bios rom],
    'an argument that is not an option' => ['--bios-path', :bios, '--rom-path', :rom, 'extra']
  }.each do |name, args|
    it "prints the usage and fails with #{name}" do
      stdout, stderr, status = bench(*args)

      expect([status.exitstatus, stdout]).to eq([1, ''])
      expect(stderr).to include('Usage: rubyboy-advance-bench --bios-path BIOS_PATH --rom-path ROM_PATH')
    end
  end

  {
    ['--count', '0'] => 'at least 1',
    ['--frames', '0'] => 'at least 1',
    ['--warmup-frames', '-1'] => 'must not be negative',
    ['--count', 'abc'] => 'invalid argument',
    ['--frames', '1.5'] => 'invalid argument'
  }.each do |extra, message|
    it "fails with #{extra.join(' ')} before it runs anything, without a stack trace" do
      stdout, stderr, status = bench('--bios-path', :bios, '--rom-path', :rom, *extra)

      expect([status.exitstatus, stdout]).to eq([1, ''])
      expect(stderr).to include(message)
      expect(stderr).not_to include(':in ')
    end
  end

  it 'fails with a BIOS that is not 16 KB' do
    stdout, stderr, status = bench('--bios-path', zeros(0x3FFF), '--rom-path', :rom)

    expect([status.exitstatus, stdout]).to eq([1, ''])
    expect(stderr).to include('16 KB')
  end
end
