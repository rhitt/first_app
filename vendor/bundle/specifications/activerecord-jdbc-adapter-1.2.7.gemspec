# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = "activerecord-jdbc-adapter"
  s.version = "1.2.7"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.authors = ["Nick Sieger, Ola Bini and JRuby contributors"]
  s.date = "2013-02-12"
  s.description = "activerecord-jdbc-adapter is a database adapter for Rails\\' ActiveRecord\ncomponent that can be used with JRuby[http://www.jruby.org/]. It allows use of\nvirtually any JDBC-compliant database with your JRuby on Rails application."
  s.email = "nick@nicksieger.com, ola.bini@gmail.com"
  s.homepage = "https://github.com/jruby/activerecord-jdbc-adapter"
  s.licenses = ["BSD"]
  s.rdoc_options = ["--main", "README.md", "-SHN", "-f", "darkfish"]
  s.require_paths = ["lib"]
  s.rubyforge_project = "jruby-extras"
  s.rubygems_version = "1.8.24"
  s.summary = "JDBC adapter for ActiveRecord, for use within JRuby on Rails."

  if s.respond_to? :specification_version then
    s.specification_version = 3

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
    else
    end
  else
  end
end
