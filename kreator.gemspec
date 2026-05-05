# frozen_string_literal: true

require_relative "lib/kreator/version"

Gem::Specification.new do |spec|
  spec.name = "kreator"
  spec.version = Kreator::VERSION
  spec.authors = ["Jorge Alvarez"]
  spec.email = ["jorge@alvareznavarro.es"]

  spec.summary = "A Ruby headless coding agent CLI runtime."
  spec.description = "A Ruby CLI agent runtime with streaming provider adapters."
  spec.homepage    = "https://github.com/jorgegorka/kreator"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "rubygems_mfa_required" => "true",
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/master/CHANGELOG.md"
  }

  spec.files = Dir["lib/**/*.rb", "lib/kreator/bundled_plugins/**/*", "exe/*", "README.md"]
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
