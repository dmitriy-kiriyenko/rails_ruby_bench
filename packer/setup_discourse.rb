#!/usr/bin/env ruby

require "fileutils"
require "json"

# Pass --local to run the setup on a local machine, or set RRB_LOCAL
LOCAL = (ARGV.delete '--local') || ENV["RRB_LOCAL"]
# Whether to build rubies with rvm
BUILD_RUBY = !LOCAL
USE_BASH = BUILD_RUBY
# Print all commands and show their full output
VERBOSE = LOCAL

base = LOCAL ? File.expand_path('..', __FILE__) : "/home/ubuntu"
benchmark_software = JSON.load(File.read("#{base}/benchmark_software.json"))

PUBLIFY_GIT_URL    = benchmark_software["publify"]["git_url"]
PUBLIFY_TAG        = benchmark_software["publify"]["git_tag"]

class SystemPackerBuildError < RuntimeError; end

print <<SETUP
=========
Running setup_publify.rb for Ruby-related software...
=========
SETUP

# Checked system - error if the command fails
def csystem(cmd, err, opts = {})
  cmd = "bash -l -c \"#{cmd}\"" if USE_BASH && opts[:bash]
  print "Running command: #{cmd.inspect}\n" if VERBOSE || opts[:debug] || opts["debug"]
  if VERBOSE
    system(cmd, out: $stdout, err: :out)
  else
    out = `#{cmd}`
  end
  unless $?.success? || opts[:fail_ok] || opts["fail_ok"]
    puts "Error running command:\n#{cmd.inspect}"
    puts "Output:\n#{out}\n=====" if out
    raise SystemPackerBuildError.new(err)
  end
end

def clone_or_update_repo(repo_url, tag, work_dir)
  unless Dir.exist?(work_dir)
    csystem "git clone #{repo_url} #{work_dir}", "Couldn't 'git clone' into #{work_dir}!", :debug => true
  end

  Dir.chdir(work_dir) do
    csystem "git fetch", "Couldn't 'git fetch' in #{work_dir}!", :debug => true

    if tag && tag.strip != ""
      tag = tag.strip
      csystem "git checkout #{tag}", "Couldn't 'git checkout #{tag}' in #{work_dir}!", :debug => true
    else
      csystem "git pull", "Couldn't 'git pull' in #{work_dir}!", :debug => true
    end
  end
end

if LOCAL
  RAILS_BENCH_DIR = File.expand_path("../..", __FILE__)
else
  RAILS_BENCH_DIR = File.join(Dir.pwd, "rails_ruby_bench")
end
PUBLIFY_DIR = File.join(RAILS_BENCH_DIR, "work", "publify")

clone_or_update_repo PUBLIFY_GIT_URL, PUBLIFY_TAG, PUBLIFY_DIR

# Install Discourse gems into RVM-standard Ruby installed for Discourse
Dir.chdir(PUBLIFY_DIR) do
  csystem "gem install bundler -v1.17.3", "Couldn't install bundler for #{PUBLIFY_DIR} for Discourse's system Ruby!", :bash => true
  csystem "bundle _1.17.3_", "Couldn't install Discourse gems for #{PUBLIFY_DIR} for Discourse's system Ruby!", :bash => true
end

if LOCAL
  puts "\nIf not done already, you should setup the dependencies for Discourse: redis, postgres and node"
  puts "https://github.com/publify/publify/blob/v1.8.0.beta13/docs/DEVELOPER-ADVANCED.md#preparing-a-fresh-ubuntu-install"
  puts
end

Dir.chdir(PUBLIFY_DIR) do
  csystem "RAILS_ENV=profile bundle _1.17.3_ exec rake db:create", "Couldn't create Rails database!", :bash => true
  csystem "RAILS_ENV=profile bundle _1.17.3_ exec rake db:migrate", "Failed running 'rake db:migrate' in #{PUBLIFY_DIR}!", :bash => true

  # TODO: use a better check for whether to rebuild precompiled assets
  unless File.exists? "public/assets"
    csystem "RAILS_ENV=profile bundle _1.17.3_ exec rake assets:precompile", "Failed running 'rake assets:precompile' in #{PUBLIFY_DIR}!", :bash => true
  end
  unless File.exists? "public/uploads"
    FileUtils.mkdir "public/uploads"
  end
  conf_db = File.read "config/database.yml"
  new_contents = conf_db.gsub("pool: 5", "pool: 30")  # Increase database.yml thread pool, including for profile environment
  if new_contents != conf_db
    File.open("config/database.yml", "w") do |f|
      f.print new_contents
    end
  end
end

puts "Add assets.rb initializer for Discourse"
# Minor bugfix for this version of Discourse. Can remove when I only use 1.8.0+ Discourse?
ASSETS_INIT = File.join(PUBLIFY_DIR, "config/initializers/assets.rb")
unless File.exists?(ASSETS_INIT)
  File.open(ASSETS_INIT, "w") do |f|
    f.write <<-INITIALIZER
      Rails.application.config.assets.precompile += %w( jquery_include.js )
    INITIALIZER
  end
end

puts "Hack to disable CSRF protection during benchmark..."
# Turn off CSRF protection for Discourse in the benchmark. I have no idea why
# user_simulator's CSRF handling stopped working between Discourse 1.7.X and
# 1.8.0.beta10, but it clearly did. This is a horrible workaround and should
# be fixed when I figure out the problem.
APP_CONTROLLER = File.join(PUBLIFY_DIR, "app/controllers/application_controller.rb")
contents = File.read(APP_CONTROLLER)
original_line = "protect_from_forgery"
patched_line = "#protect_from_forgery"
unless contents[patched_line]
  File.open(APP_CONTROLLER, "w") do |f|
    f.print contents.gsub(original_line, patched_line)
  end
end

# Oh and hey, looks like Bootsnap breaks something in the load order when
# including config/environment into start.rb. Joy.
# TODO: merge this patching into a little table of patches?
path = File.join(PUBLIFY_DIR, "config/boot.rb")
contents = File.read(path)
original_line = "if ENV['RAILS_ENV'] != 'production'"
patched_line = "if ENV['RAILS_ENV'] != 'production' && ENV['RAILS_ENV'] != 'profile'"
unless contents[patched_line]
  File.open(path, "w") do |f|
    f.print contents.gsub(original_line, patched_line)
  end
end

FileUtils.touch "/tmp/setup_publify_ran_correctly"
