# frozen_string_literal: true

require_relative "lib/rettle/version"

Gem::Specification.new do |spec|
  spec.name = "rettle"
  spec.version = Rettle::VERSION
  spec.authors = ["longicorn"]
  spec.email = ["longicorn.c@gmail.com"]

  spec.summary = "Rettle is simple ETL for Ruby."
  spec.description = "Rettle is simple ETL for Ruby."
  spec.homepage = "https://github.com/longicorn/rettle.git"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "nkf"
end
