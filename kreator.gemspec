# frozen_string_literal: true

require_relative "lib/kreator/version"

Gem::Specification.new do |spec|
  spec.name = "kreator"
  spec.version = Kreator::VERSION
  spec.authors = ["Kreator Contributors"]
  spec.email = ["dev@example.com"]

  spec.summary = "A Ruby headless coding agent CLI runtime."
  spec.description = "A Ruby 3.2+ CLI agent runtime with streaming provider adapters."
  spec.homepage = "https://example.com/kreator"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["allowed_push_host"] = "TODO: Set to your gem server"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["kreator"]
  spec.require_paths = ["lib"]

  spec.add_dependency "bubbles", "~> 0.1"
  spec.add_dependency "bubbletea", "~> 0.1"
  spec.add_dependency "diff-lcs", "~> 1.5"
  spec.add_dependency "glamour", "~> 0.1"
  spec.add_dependency "json_schemer", "~> 2.3"
  spec.add_dependency "lipgloss", "~> 0.1"
end
