# encoding: utf-8

# Copyright (c) 2012, HipByte SPRL and contributors
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

require 'motion/project/app'

App = Motion::Project::App
App.template = :osx

require 'motion/project'
require 'motion/project/template/osx/config'
require 'motion/project/template/osx/builder'
require 'motion/project/template/osx/notarizer'
require 'motion/project/repl_launcher'

desc "Build the project, then run it"
task :default => :run

namespace :build do
  desc "Build the project for development"
  task :development do
    App.build('MacOSX')
    App.codesign('MacOSX') if App.config_without_setup.codesign_for_development
  end

  desc "Build the project for release"
  task :release do
    App.config_without_setup.build_mode = :release
    App.build('MacOSX')
    App.codesign('MacOSX') if App.config_without_setup.codesign_for_release
  end

end

desc "Build everything"
task :build => ['build:development', 'build:release']

desc "Run the project"
task :run do
  unless ENV["skip_build"]
    Rake::Task["build:development"].invoke
  end
  exec = App.config.app_bundle_executable('MacOSX')
  env = ''
  if App.config.needs_repl_sandbox_entitlements?
    env << "REPL_SOCKET_PATH='#{App.config.app_sandbox_repl_socket_path}' "
  end
  App.info 'Run', exec
  at_exit { system("stty echo") } if $stdout.tty? # Just in case the process crashes and leaves the terminal without echo.
  Signal.trap(:INT) {} if ENV['debug']

  if App.config.archs["MacOSX"].include?("x86_64")
    kernel = File.join(App.config.datadir, "MacOSX", "kernel-x86_64.bc")
  else
    kernel = File.join(App.config.datadir, "MacOSX", "kernel-i386.bc")
  end

  repl_launcher = Motion::Project::REPLLauncher.new({
    "app-bundle-path" => exec,
    "xcode-path" => App.config.xcode_dir,
    "arguments" => ENV['args'],
    "debug-mode" => !!ENV['debug'],
    "spec-mode" => App.config.spec_mode,
    "kernel-path" => kernel,
    "local-port" => App.config.local_repl_port('MacOSX'),
    "device-hostname" => "0.0.0.0",
    "platform" => "MacOSX",
    "sdk-version" => App.config.sdk_version,
    "bs_files" => [App.config.bridgesupport_files, App.config.vendor_projects.map(&:bs_files)].flatten,
    "verbose" => App::VERBOSE
  })

  repl_launcher.launch

  App.config.print_crash_message if $?.exitstatus != 0 && !App.config.spec_mode
  exit($?.exitstatus)
end

desc "Run the test/spec suite"
task :spec do
  App.config_without_setup.spec_mode = true
  Rake::Task["run"].invoke
end

desc "Create a .pkg archive"
task :archive => 'build:release' do
  App.archive
end

namespace :archive do
  desc "Create a .pkg archive for distribution (AppStore)"
  task :distribution do
    App.config_without_setup.distribution_mode = true
    Rake::Task['archive'].invoke
  end
end

desc "Build and notarize the project for release"
task :notarize do
  App.config_without_setup.build_mode = :release
  notarizer = Motion::Project::Notarizer.new(App.config, 'MacOSX')
  notarizer.notarize
end

namespace :notarize do
  desc "Build and notarize the project for release and wait for acceptance"
  task :wait do
    App.config_without_setup.build_mode = :release
    notarizer = Motion::Project::Notarizer.new(App.config, 'MacOSX')
    notarizer.notarize(true)
  end

  desc "Staple the notarization ticket to your app"
  task :staple do
    App.config_without_setup.build_mode = :release
    notarizer = Motion::Project::Notarizer.new(App.config, 'MacOSX')
    notarizer.staple
  end

  desc "List the latest notarization attempts"
  task :history do
    App.config_without_setup.build_mode = :release
    notarizer = Motion::Project::Notarizer.new(App.config, 'MacOSX')
    notarizer.show_history
  end
end

desc "Create a .a static library"
task :static do
  App.build('MacOSX', :static => true)
end

def profiler_templates
  App.config.profiler_known_templates
end

namespace :profile do
  %w(development release).each do |mode|
    desc "Run a #{mode} build through Instruments"
    task mode => "build:#{mode}" do
      plist = App.config.profiler_config_plist('MacOSX', "-NSDocumentRevisionsDebugMode YES #{ENV['args']}", ENV['template'], profiler_templates)
      App.profile('MacOSX', plist)
    end
  end

  desc 'List all built-in OS X Instruments templates'
  task :templates do
    puts "Built-in OS X Instruments templates:"
    profiler_templates.each do |template|
      puts "* #{template}"
    end
  end
end

desc 'Same as profile:development'
task :profile => 'profile:development'

desc "Open the latest crash report generated for the app"
task :crashlog => :__local_crashlog
