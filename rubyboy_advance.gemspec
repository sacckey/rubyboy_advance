# frozen_string_literal: true

require_relative 'lib/rubyboy_advance/version'

Gem::Specification.new do |spec|
  spec.name = 'rubyboy_advance'
  spec.version = RubyboyAdvance::VERSION
  spec.authors = ['sacckey']

  spec.summary = 'A Game Boy Advance emulator written in Ruby'
  spec.homepage = 'https://github.com/sacckey/rubyboy_advance'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 4.0.0'

  spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Test ROMs stay in the repository.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z lib exe LICENSE README.md`.split("\x0")
  end
  spec.bindir = 'exe'
  spec.executables = ['rubyboy-advance']
  spec.require_paths = ['lib']
end
