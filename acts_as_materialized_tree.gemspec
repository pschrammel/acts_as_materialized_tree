require 'rake'
 
PKG_NAME='acts_as_materialized_tree'
PKG_VERSION= "0.0.2"
PKG_FILE_NAME   = "#{PKG_NAME}-#{PKG_VERSION}"
 
PKG_GEM=Gem::Specification.new do |s|
  s.name = PKG_NAME
  s.version = PKG_VERSION
 
  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.authors = ["Brian Candler"]
  s.date = %q{2009-02-26}
  s.description = %q{An insert- and query-efficient tree model.}
  s.email = "peter.schrammel@gmx.de"
  s.platform  = Gem::Platform::RUBY
  s.files  = FileList["{lib,test}/**/*"].to_a + %w( init.rb  Rakefile  README.rdoc)
  s.has_rdoc = true
  s.rdoc_options = ["--main", "README.rdoc"]
  s.require_paths = ["lib"]
  s.add_dependency  "rails", ">= 2.1.0"
  s.rubygems_version = %q{1.3.0}
  s.summary = "#{PKG_NAME} #{PKG_VERSION}"
end
 
PKG_GEM
