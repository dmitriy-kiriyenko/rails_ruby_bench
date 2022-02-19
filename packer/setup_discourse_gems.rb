#!/usr/bin/env ruby

require "fileutils"
require "json"

# Pass --local to run the setup on a local machine, or set RRB_LOCAL
LOCAL = (ARGV.delete '--local') || ENV["RRB_LOCAL"]
# Whether to build rubies with rvm
BUILD_RUBY = !LOCAL
USE_BASH = BUILD_RUBY
# Print all commands and show their full output
#VERBOSE = LOCAL
VERBOSE = true

base = LOCAL ? File.expand_path('..', __FILE__) : "/home/ubuntu"
benchmark_software = JSON.load(File.read("#{base}/benchmark_software.json"))

class SystemPackerBuildError < RuntimeError; end

print <<SETUP
=========
Running setup_publify_gems.rb for Ruby-related software...
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

if LOCAL
  RAILS_BENCH_DIR = File.expand_path("../..", __FILE__)
else
  RAILS_BENCH_DIR = File.join(Dir.pwd, "rails_ruby_bench")
end
PUBLIFY_DIR = File.join(RAILS_BENCH_DIR, "work", "publify")

# Installing the Discourse gems takes awhile. Like, a *long*
# while. And Packer turns out to have a bug where a step that takes
# over five minutes can quietly fail without raising an error. So not
# only do we touch the file (to make sure this worked), we also split
# out installing Discourse's gems into its own step.

benchmark_software["compare_rubies"].each do |ruby_hash|
  ruby_hash["found_name"] = ruby_hash["rvm_name"] || ruby_hash["name"]
end

first_ruby = nil
# We can't easily match up the benchmark_software entries with Ruby names...
Dir["#{ENV["HOME"]}/.rvm/rubies/*"].each do |ruby_name|
  ruby_name = ruby_name.split("/")[-1]
  next if ["default", "ruby-2.4.1"].include?(ruby_name)  # Don't bother with the system Ruby or default

  # ruby_name should contain one of the Ruby Names from benchmark_software - check if we should install Discourse
  # gems, which is useless (and sometimes impossible) on older Rubies.
  match_hash = benchmark_software["compare_rubies"].detect { |hash| ruby_name[hash["found_name"]] }
  if match_hash
    if !match_hash.has_key?("publify") || match_hash["publify"]
      first_ruby ||= ruby_name  # What's the first comparison Ruby that installs Discourse gems?
      puts "Install Discourse gems in Ruby: #{ruby_name.inspect}"
      Dir.chdir(RAILS_BENCH_DIR) do
        csystem "rvm use #{ruby_name} && gem install bundler -v1.17.3 && bundle _1.17.3_", "Couldn't install Discourse gems in #{PUBLIFY_DIR} for Ruby #{ruby_name.inspect}!", :bash => true
      end
    end
  end
end

if !first_ruby
  raise "Couldn't find any Discourse-capable Ruby to run the benchmark..."
end

# And check to make sure the benchmark actually runs... But just do a few iterations.
Dir.chdir(RAILS_BENCH_DIR) do
  begin
    csystem "rvm use #{first_ruby} && bundle exec ./start.rb -s 1 -n 1 -i 10 -w 0 -o /tmp/ -c 1", "Couldn't successfully run the benchmark!", :bash => true
  rescue SystemPackerBuildError
    # Before dying, let's look at that Rails logfile... Redirect stdout to stderr.
    print "Error running test iterations of the benchmark, printing Rails log to console!\n==========\n"
    print `tail -60 work/publify/log/profile.log`   # If we echo too many lines they just get cut off by Packer
    print "=============\n"
    raise # Re-raise the error, we still want to die.
  end
end

FileUtils.touch "/tmp/setup_publify_gems_ran_correctly"
