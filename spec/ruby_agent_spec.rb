# frozen_string_literal: true

require_relative 'spec_helper'

class RubyAgentSpec < Minitest::Test
  def test_core_components_load_without_zeitwerk
    assert RubyAgent.const_defined?(:Doc)
    assert RubyAgent.const_defined?(:DocPlugin)
    assert RubyAgent.const_defined?(:DocHub)
  end

  def test_doc_hub_is_exposed_as_singleton
    assert_kind_of RubyAgent::DocHub, RubyAgent.doc_hub
  end

  def test_loader_returns_zeitwerk_loader_when_zeitwerk_available
    begin
      require 'zeitwerk'
    rescue LoadError
      skip 'zeitwerk 未安装（当前沙箱环境）'
    end

    assert_kind_of Zeitwerk::Loader, RubyAgent.loader
  end
end
