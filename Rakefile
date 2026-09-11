# frozen_string_literal: true

require 'fileutils'

def spec_files
  Dir[File.expand_path('spec/**/*_spec.rb', __dir__)].sort
end

namespace 'ruby_agent' do
  desc 'Run tests (minitest)'
  task test: 'test:only'

  task 'test:only' do
    spec_files.each { |file| ruby "-Ilib -Ispec #{file}" }
  end

  desc 'Run tests with verbose output'
  task 'test:verbose' do
    ENV['TESTOPTS'] = '--verbose'
    spec_files.each { |file| ruby "-Ilib -Ispec #{file}" }
  end

  desc 'Clean generated files'
  task :clean do
    FileUtils.rm_rf(%w[coverage .rspec_status])
  end
end

task default: 'ruby_agent:test'
