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

RAILS_RUBY_BENCH_URL = ENV["RAILS_RUBY_BENCH_URL"]  # Cloned in ami.json
RAILS_RUBY_BENCH_TAG = ENV["RAILS_RUBY_BENCH_TAG"]

PUBLIFY_DIR = ENV["PUBLIFY_DIR"] || File.join(__dir__, "work", "publify")
PUBLIFY_URL = ENV["PUBLIFY_URL"] || benchmark_software["publify"]["git_url"]
PUBLIFY_TAG = ENV["PUBLIFY_TAG"] || benchmark_software["publify"]["git_tag"]

class SystemPackerBuildError < RuntimeError; end

print <<SETUP
=========
Running setup.rb for Ruby-related software.
RAILS_RUBY_BENCH_URL: #{RAILS_RUBY_BENCH_URL.inspect}
RAILS_RUBY_BENCH_TAG: #{RAILS_RUBY_BENCH_TAG.inspect}

Benchmark Software:
#{JSON.pretty_generate(benchmark_software)}
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

def clone_or_update_by_json(h, work_dir)
  clone_or_update_repo(h["git_url"], h["git_tag"], h["checkout_dir"] || work_dir)
end

def build_and_mount_ruby(source_dir, prefix_dir, mount_name, options = {})
  puts "Build and mount Ruby: Source dir: #{source_dir.inspect} Prefix dir: #{prefix_dir.inspect} Mount name: #{mount_name.inspect}"
  Dir.chdir(source_dir) do
    unless File.exists?("configure")
      csystem "autoconf", "Couldn't run autoconf in #{source_dir}!"
    end
    unless File.exists?("Makefile")
      configure_options = options["configure_options"] || ""
      csystem "./configure --prefix #{prefix_dir} #{configure_options}", "Couldn't run configure in #{source_dir}!"
    end
    csystem "make", "Make failed in #{source_dir}!"
    # This should install to the benchmark ruby dir
    csystem "make install", "Installing Ruby failed in #{source_dir}!"
  end
  csystem "rvm mount #{prefix_dir} -n #{mount_name}", "Couldn't mount #{source_dir.inspect} as #{mount_name}!", :bash => true
  csystem "rvm use --default ext-#{mount_name}", "Couldn't set ext-#{mount_name} to rvm default!", :bash => true
end

def autogen_name
  @autogen_number ||= 1
  name = "autogen-name-#{@autogen_number}"
  @autogen_number += 1
  name
end

def clone_or_update_ruby_by_json(h, work_dir)
  clone_or_update_by_json(h, work_dir)
  mount_name = h["name"] || autogen_name
  prefix_dir = h["prefix_dir"] || File.join(RAILS_BENCH_DIR, "work", "prefix", mount_name.gsub("/", "_"))

  build_and_mount_ruby(h["checkout_dir"], prefix_dir, mount_name, { "configure_options" => h["configure_options"] || "" } )
  h["mount_name"] = "ext-" + mount_name
end

# When you run with "rvm use", you wind up with a bunch of extra
# output that you usually don't want.  You need to cut out just the
# last line, remove extraneous newlines, make sure .bash_profile has
# been sourced...
def last_line_with_ruby(cmd, ruby)
  output = `bash -l -c \"rvm use #{ruby} && #{cmd}\"`
  unless $?.success?
    puts "Something went wrong running command, returning nil... #{$?.inspect} / #{cmd.inspect}"
    return nil
  end
  output.split("\n").compact[-1]
end

if LOCAL
  RAILS_BENCH_DIR = File.expand_path("../..", __FILE__)
else
  RAILS_BENCH_DIR = File.join(Dir.pwd, "rails_ruby_bench")
end

# Cloned in ami.json, but go ahead and update anyway. This shouldn't normally do anything.
if RAILS_RUBY_BENCH_URL && RAILS_RUBY_BENCH_URL.strip != ""
  Dir.chdir(RAILS_BENCH_DIR) do
    csystem "git remote add benchmark-url #{RAILS_RUBY_BENCH_URL} && git fetch benchmark-url", "error fetching commits from Rails Ruby Bench at #{RAILS_RUBY_BENCH_URL.inspect}"
    if RAILS_RUBY_BENCH_TAG.strip != ""
      csystem "git checkout benchmark-url/#{RAILS_RUBY_BENCH_TAG}", "Error checking out Rails Ruby Bench tag #{RAILS_RUBY_BENCH_TAG.inspect}"
    end
  end
end

# Install Rails Ruby Bench gems into system Ruby
Dir.chdir(RAILS_BENCH_DIR) do
  csystem "gem install bundler -v1.17.3", "Couldn't install bundler for #{RAILS_BENCH_DIR} for system Ruby!", :bash => true
  csystem "bundle _1.17.3_", "Couldn't install RRB gems for #{RAILS_BENCH_DIR} for system Ruby!", :bash => true
end

if BUILD_RUBY
  benchmark_software["compare_rubies"].each do |ruby_hash|
    puts "Installing Ruby: #{ruby_hash.inspect}"
    # Clone the Ruby, then build and mount if necessary
    if ruby_hash["git_url"]
      work_dir = File.join(RAILS_BENCH_DIR, "work", ruby_hash["name"])
      ruby_hash["checkout_dir"] = work_dir
      clone_or_update_ruby_by_json(ruby_hash, work_dir)

      #csystem "rvm list #2", "Error running rvm list [2] on Ruby #{ruby_hash.inspect}!", :debug => true
      puts "Mount the built Ruby: #{ruby_hash.inspect}"

      rvm_ruby_name = ruby_hash["mount_name"] || ruby_hash["name"]
      Dir.chdir(RAILS_BENCH_DIR) do
        # In Ruby 2.6.0preview3 and later, Bundler is installed as part of Ruby. Check if that's present.
        bundle_path = last_line_with_ruby("which bundle", rvm_ruby_name)

        puts "Checking bundler path: #{bundle_path.inspect}"
        if !bundle_path || bundle_path == ''
          # Okay, so no Bundler is in the path yet. Install the gem.
          puts "No builtin or installed Bundler, installing the gem"
          csystem "rvm use #{rvm_ruby_name} && gem install bundler -v1.17.3", "Couldn't install Bundler in #{RAILS_BENCH_DIR} for Ruby #{rvm_ruby_name.inspect}!", :bash => true
        end

        if !ruby_hash.has_key?("publify") || ruby_hash["publify"]
          which_bundle = last_line_with_ruby("which bundle", rvm_ruby_name)
          puts "Fell through, trying to run bundle. Executable: #{which_bundle.inspect}"
          csystem "rvm use #{rvm_ruby_name} && bundle _1.17.3_", "Couldn't install RRB gems in #{RAILS_BENCH_DIR} for Ruby #{rvm_ruby_name.inspect}!", :bash => true
        end
      end

    elsif ruby_hash["rvm_name"]
      csystem "rvm install #{ruby_hash["rvm_name"]}", "Couldn't use RVM to install Ruby named #{ruby_hash["rvm_name"]}!"
      if ruby_hash["publify"]
        csystem "rvm use #{ruby_hash["rvm_name"]} && cd #{RAILS_BENCH_DIR} && bundle _1.17.3_", "Couldn't install RRB gems in #{RAILS_BENCH_DIR} for RVM-installed Ruby #{ruby_hash["rvm_name"]}!", :bash => true
      end
      csystem "rvm use #{ruby_hash["rvm_name"]} && gem install bundler -v1.17.3", "Couldn't install Bundler in #{RAILS_BENCH_DIR} for Ruby #{ruby_hash["rvm_name"].inspect}!", :bash => true
    end

  end

  puts "Create benchmark_ruby_versions.txt"
  File.open("/home/ubuntu/benchmark_ruby_versions.txt", "w") do |f|
    rubies = benchmark_software["compare_rubies"].map { |h| h["mount_name"] || h["name"] || h["rvm_name"] || h["name"] }
    f.print rubies.join("\n")
  end
end

clone_or_update_repo(PUBLIFY_URL, PUBLIFY_TAG, PUBLIFY_DIR)

if LOCAL
  Dir.chdir(PUBLIFY_DIR) { csystem "bundle _1.17.3_", "Couldn't install Discourse gems into system Ruby!", :bash => true }
end

Dir.chdir(RAILS_BENCH_DIR) do
  # If there are already users added, this should exit without error and not change the database
  puts "Adding seed data..."
  csystem "RAILS_ENV=profile ruby seed_db_data.rb", "Couldn't seed the database with profiling sample data!", :bash => true
end

FileUtils.touch "/tmp/setup_ran_correctly"
