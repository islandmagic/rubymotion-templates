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

require 'motion/project/config'
require 'motion/util/code_sign'
require 'motion/project/target'
require 'socket'

module Motion; module Project
  class XcodeConfig < Config
    variable :xcode_dir, :sdk_version, :deployment_target, :frameworks,
             :weak_frameworks, :embedded_frameworks, :external_frameworks, :framework_search_paths,
             :embedded_dylibs, :swift_version,
             :libs, :identifier, :codesign_certificate, :short_version, :entitlements, :delegate_class, :embed_dsym,
             :version

    def initialize(project_dir, build_mode)
      super
      @info_plist = {}
      @frameworks = []
      @weak_frameworks = []
      @embedded_frameworks = []
      @external_frameworks = []
      @framework_search_paths = []
      @embedded_dylibs = []
      @libs = []
      @targets = []
      @bundle_signature = '????'
      @short_version = nil
      @entitlements = {}
      @delegate_class = 'AppDelegate'
      @spec_mode = false
      @embed_dsym = (development? ? true : false)
      @vendor_projects = []
      @version = '1.0'
      @swift_version = `xcrun swift -version`.strip.match(/Apple Swift version ([\d\.]+)/)[1]
      XcodeConfig.check_for_sdk_dir_with_explicit_version(xcode_developer_dir: xcode_dir, platform_names: self.platforms)
    end

    def XcodeConfig.check_for_sdk_dir_with_explicit_version(xcode_developer_dir:, platform_names:)
      platform_names.each do |platform|
        sdk_version = get_sdk_version(xcode_developer_dir: xcode_developer_dir,
                                      platform_name: platform)
        without_version_dir = sdk_dir_without_version(xcode_developer_dir: xcode_developer_dir,
                                                      platform_name: platform)
        with_version_dir = sdk_dir_with_version(xcode_developer_dir: xcode_developer_dir,
                                                platform_name: platform)
        if !Dir.exist?(with_version_dir) && Dir.exist?(without_version_dir)
          App.fail <<~S
                   * ERROR: Explicit SDK directory required.
                   Please run the following command to create an explicitly named SDK directory (you may need to use sudo):

                   ln -s #{without_version_dir} #{with_version_dir}

                   S
        end
      end
    end

    def XcodeConfig.sdk_dir_without_version(xcode_developer_dir:, platform_name:)
      xcode_developer_dir = File.expand_path(xcode_developer_dir)
      sdk_dir = File.join(xcode_developer_dir, "Platforms/#{platform_name}.platform/Developer/SDKs/#{platform_name}.sdk")
    end

    def XcodeConfig.sdk_dir_with_version(xcode_developer_dir:, platform_name:)
      xcode_developer_dir = File.expand_path(xcode_developer_dir)
      version = get_sdk_version(xcode_developer_dir: xcode_developer_dir, platform_name: platform_name)
      sdk_dir = File.join(xcode_developer_dir, "Platforms/#{platform_name}.platform/Developer/SDKs/#{platform_name}#{version}.sdk")
    end

    def XcodeConfig.sdk_settings_path(xcode_developer_dir:, platform_name:)
      xcode_developer_dir = File.expand_path(xcode_developer_dir)
      platform_dir = File.join(xcode_developer_dir, "Platforms/#{platform_name}.platform")
      sdk_settings_path = File.join(platform_dir, "Developer", "SDKs", "#{platform_name}.sdk", "SDKSettings.plist")
      sdk_settings_path
    end

    def XcodeConfig.get_sdk_version(xcode_developer_dir:, platform_name:)
      xcode_developer_dir = File.expand_path(xcode_developer_dir)
      platform_dir = File.join(xcode_developer_dir, "Platforms/#{platform_name}.platform")
      sdk_settings_path = File.join(platform_dir, "Developer", "SDKs", "#{platform_name}.sdk", "SDKSettings.plist")
      if !File.exist?(sdk_settings_path)
        puts <<~S
              * ERROR: SDKSettings.plist not found.
              Looking for SDKSettings.plist at #{sdk_settings_path}

              XCode may be incorrectly installed. Please try reinstalling XCode.
              S
        exit 1
      end
      plist_buddy_cmd = "/usr/libexec/PlistBuddy -c \"Print :Version\" #{sdk_settings_path}"
      sdk_version = `#{plist_buddy_cmd}`.strip
      sdk_version
    end

    def xcode_dir=(xcode_dir)
      @xcode_version = nil
      @xcode_dir = unescape_path(File.path(xcode_dir))
    end

    def xcode_dir
      @xcode_dir ||= begin
        if ENV['RM_TARGET_XCODE_DIR']
          ENV['RM_TARGET_XCODE_DIR']
        else
          xcodeselect = '/usr/bin/xcode-select'
          xcode_dir = unescape_path(`#{xcodeselect} -print-path`.strip)
          App.fail "Can't locate any version of Xcode on the system." unless File.exist?(xcode_dir)
          xcode_dir
        end
      end
    end

    def xcode_version
      @xcode_version ||= begin
        failed = false
        vers = `/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "#{xcode_dir}/../Info.plist"`.strip
        failed = true if !$?.success?
        build = `/usr/libexec/PlistBuddy -c "Print :ProductBuildVersion" "#{xcode_dir}/../version.plist"`.strip
        failed = true if !$?.success?
        if failed
          txt = `#{locate_binary('xcodebuild')} -version`
          vers = txt.scan(/Xcode\s(.+)/)[0][0]
          build = txt.scan(/(BuildVersion:|Build version)\s(.+)/)[0][1]
        end
        [vers, build]
      end
    end

    def platforms; raise; end
    def local_platform; raise; end
    def deploy_platform; raise; end

    def xcode_metadata
      {
        '10.3' => {
          :llvm  => 500,
          :osx   => '10.14',
          :ios   => '12.4',
          :tv    => '12.4',
          :watch => '5.3',
          :clang => 'Apple LLVM version 10.0.1 (clang-1001.0.46.4)'
        },
        '11.0' => {
          :llvm  => 900,
          :osx   => '10.15',
          :ios   => '13.0',
          :tv    => '13.0',
          :watch => '6.0',
          :clang => ''
        },
        '11.1' => {
          :llvm  => 900,
          :osx   => '10.15',
          :ios   => '13.1',
          :tv    => '13.0',
          :watch => '6.0',
          :clang => ''
        },
        '11.2.1' => {
          :llvm  => 900,
          :osx   => '10.15',
          :ios   => '13.2',
          :tv    => '13.2',
          :watch => '6.1',
          :clang => 'Apple clang version 11.0.0 (clang-1100.0.33.12)'
        },
        '11.3.1' => {
          :llvm  => 900,
          :osx   => '10.15',
          :ios   => '13.2',
          :tv    => '13.2',
          :watch => '6.1',
          :clang => 'Apple clang version 11.0.0 (clang-1100.0.33.12)'
        },
        '11.4' => {
          :llvm  => 900,
          :osx   => '10.15',
          :ios   => '13.4',
          :tv    => '13.4',
          :watch => '6.2',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '11.4.1' => {
          :llvm  => 900,
          :osx   => '10.15',
          :ios   => '13.4',
          :tv    => '13.4',
          :watch => '6.2',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '11.5' => {
          :llvm  => 900,
          :osx   => '10.15',
          :ios   => '13.5',
          :tv    => '13.4',
          :watch => '6.2',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '11.5.1' => {
          :llvm  => 900,
          :osx   => '10.15',
          :ios   => '13.5',
          :tv    => '13.4',
          :watch => '6.2',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '11.6' => {
          :llvm  => 900,
          :osx   => '10.15',
          :ios   => '13.6',
          :tv    => '13.4',
          :watch => '6.2',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '11.7' => {
          :llvm  => 900,
          :osx   => '10.15',
          :ios   => '13.7',
          :tv    => '13.4',
          :watch => '6.2',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '12.0' => {
          :llvm  => 900,
          :osx   => '10.15',
          :ios   => '14.0',
          :tv    => '14.0',
          :watch => '7.0',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '12.0.1' => {
          :llvm  => 900,
          :osx   => '10.15',
          :ios   => '14.0',
          :tv    => '14.0',
          :watch => '7.0',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '12.1' => {
          :llvm  => 900,
          :osx   => '10.15',
          :ios   => '14.1',
          :tv    => '14.1',
          :watch => '7.0',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '12.1.1' => {
          :llvm  => 900,
          :osx   => '10.15',
          :ios   => '14.2',
          :tv    => '14.2',
          :watch => '7.1',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '12.2' => {
          :llvm  => 900,
          :osx   => '11.0',
          :ios   => '14.2',
          :tv    => '14.2',
          :watch => '7.1',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '12.3' => {
          :llvm  => 900,
          :osx   => '11.1',
          :ios   => '14.3',
          :tv    => '14.3',
          :watch => '7.2',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '12.4' => {
          :llvm  => 900,
          :osx   => '11.1',
          :ios   => '14.4',
          :tv    => '14.4',
          :watch => '7.2',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '12.5' => {
          :llvm  => 900,
          :osx   => '11.3',
          :ios   => '14.5',
          :tv    => '14.5',
          :watch => '7.4',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '12.5.1' => {
          :llvm  => 900,
          :osx   => '11.3',
          :ios   => '14.5',
          :tv    => '14.5',
          :watch => '7.4',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '13.0' => {
          :llvm  => 900,
          :osx   => '12.0',
          :ios   => '15.0',
          :tv    => '15.0',
          :watch => '8.0',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '13.1' => {
          :llvm  => 900,
          :osx   => '12.0',
          :ios   => '15.0',
          :tv    => '15.0',
          :watch => '8.0',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '13.2.1' => {
          :llvm  => 900,
          :osx   => '12.1',
          :ios   => '15.2',
          :tv    => '15.2',
          :watch => '8.0',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '13.3' => {
          :llvm  => 900,
          :osx   => '12.3',
          :ios   => '15.4',
          :tv    => '15.4',
          :watch => '8.5',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '13.4' => {
          :llvm  => 900,
          :osx   => '12.3',
          :ios   => '15.5',
          :tv    => '15.5',
          :watch => '8.5',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '14.0' => {
          :llvm  => 900,
          :osx   => '12.3',
          :ios   => '16.0',
          :tv    => '16.0',
          :watch => '8.5',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '14.1' => {
          :llvm  => 900,
          :osx   => '13.0',
          :ios   => '16.1',
          :tv    => '16.1',
          :watch => '8.5',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '14.2' => {
          :llvm  => 900,
          :osx   => '13.1',
          :ios   => '16.2',
          :tv    => '16.2',
          :watch => '8.5',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '14.3' => {
          :llvm  => 900,
          :osx   => '13.3',
          :ios   => '16.4',
          :tv    => '16.4',
          :watch => '8.5',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '14.3.1' => {
          :llvm  => 900,
          :osx   => '13.3',
          :ios   => '16.4',
          :tv    => '16.4',
          :watch => '8.5',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '15.0' => {
          :llvm  => 900,
          :osx   => '14.0',
          :ios   => '17.0',
          :tv    => '17.0',
          :watch => '8.5',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '15.0.1' => {
          :llvm  => 900,
          :osx   => '14.0',
          :ios   => '17.0.1',
          :tv    => '17.0.1',
          :watch => '8.5',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '15.1' => {
          :llvm  => 900,
          :osx   => '14.2',
          :ios   => '17.2',
          :tv    => '17.2',
          :watch => '8.5',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
        '15.2' => {
          :llvm  => 900,
          :osx   => '14.2',
          :ios   => '17.2',
          :tv    => '17.2',
          :watch => '8.5',
          :clang => 'Apple clang version 11.0.3 (clang-1103.0.32.29)'
        },
      }
    end

    def xcode_metadata_to_s version_strings = []
      if version_strings.is_a? String
        version_strings = [version_strings]
      end

      result = version_strings.map do |version_string|
        xcode_metadata.map do |k, v|
          if version_string == v[:ios] || version_string == v[:osx] || version_string == v[:tv] || version_string == v[:watch]
            <<-S.strip
* Xcode #{k}
** OSX:    #{v[:osx]}
** iOS:    #{v[:ios]}
** TV:     #{v[:tv]}
** Watch:  #{v[:watch]}
S
          else
            nil
          end
        end.compact
      end.flatten.join "\n"

      if result.strip.length > 0
        return "* Please install (one off) the following version(s) of Xcode. You can download any version of Xcode from http://developer.apple.com/downloads:\n#{result}"
      else
        return ""
      end
    rescue Exception => e
      return ""
    end

    def validate
      App.fail "OS X 10.9 or greater is required" if osx_host_version < Util::Version.new('10.9')
      App.fail "Xcode 6.x or greater is required" if Util::Version.new(xcode_version[0]) < Util::Version.new('6.0')

      # sdk_version
      platforms.each do |platform|
        sdk_path = File.join(platforms_dir, platform + '.platform',
                             "Developer/SDKs/#{platform}#{sdk_version}.sdk")
        unless File.exist?(sdk_path)
          App.fail "Can't locate #{platform} SDK #{sdk_version} at `#{sdk_path}'"
        end
      end

      # deployment_target
      if Util::Version.new(deployment_target) > Util::Version.new(sdk_version)
        App.fail "Deployment target `#{deployment_target}' must be equal or lesser than SDK version `#{sdk_version}'\n#{xcode_metadata_to_s sdk_version}"
      end

      unless File.exist?(datadir)
        versions = Dir.glob(File.join(platforms_dir, "#{deploy_platform}.platform/Developer/SDKs/#{deploy_platform}[1-9]*.sdk")).sort.map do |path|
          File.basename(path).scan(/#{deploy_platform}(.*)\.sdk/)[0][0]
        end

        App.fail <<-S
* ERROR: Deployment target #{deployment_target} is not supported by this version of RubyMotion.

If you are using the Starter Version:
1. Make sure you are running the latest version of XCode.
2. Make sure both ~app.deployment_target~ and ~app.sdk_version~ are
   commented out in the ~Rakefile~.
3. If you've recently updated to a new version of RubyMotion or Xcode,
   be sure to open Xcode at least once, run ~sudo xcode-select --reset~,
   and then ~rake clean:all default~.
4. If you need more help, come to the Slack Channel: http://slack.rubymotion.com.
#{xcode_metadata_to_s supported_sdk_versions(versions)}
S
      end

      if (Util::Version.new(sdk_version) >= Util::Version.new("11.4") &&
          (platforms.include?('iPhoneOS') || platforms.include?('iPhoneSimulator')) &&
          frameworks.include?('AVFoundation'))
        frameworks << 'CoreMedia'
        frameworks << 'CFNetwork'
        frameworks << 'Foundation'
        frameworks << 'AudioToolbox'
        frameworks << 'CoreMedia'
        frameworks << 'CoreImage'
        frameworks << 'CoreFoundation'
        frameworks << 'MediaToolbox'
        frameworks << 'CoreGraphics'
        frameworks << 'VideoToolbox'
        frameworks << 'MobileCoreServices'
        frameworks << 'QuartzCore'
        frameworks << 'CoreVideo'
        frameworks << 'ImageIO'
        frameworks << 'Security'
        frameworks << 'Accelerate'
        frameworks.uniq!
      end

      if (Util::Version.new(sdk_version) >= Util::Version.new("12.0"))
        frameworks << "QuartzCore"
        frameworks << "CoreServices"
        frameworks.uniq!
      end

      # embedded_frameworks
      %w(embedded_frameworks external_frameworks).each do |attr|
        value = send(attr)
        if !(value.is_a?(Array) and value.all? { |x| File.exist?(x) and File.extname(x) == '.framework' })
          App.fail "app.#{attr} should be an array of framework paths (and the paths must exist)."
        end
      end

      super
    end

    def platforms_dir
      File.join(xcode_dir, 'Platforms')
    end

    def platform_dir(platform)
      File.join(platforms_dir, platform + '.platform')
    end

    def XcodeConfig.derived_sdk_version(xcode_developer_dir:, platform_name:)
      xcode_developer_dir = File.expand_path(xcode_developer_dir)
      platform_dir = File.join(xcode_developer_dir, "Platforms/#{platform_name}.platform")
      sdk_settings_path = File.join(platform_dir, "Developer", "SDKs", "#{platform_name}.sdk", "SDKSettings.plist")
      if !File.exist?(sdk_settings_path)
        puts <<~S
              * ERROR: SDKSettings.plist not found.
              Looking for SDKSettings.plist at #{sdk_settings_path}

              XCode may be incorrectly installed. Please try reinstalling XCode.
              S
        exit 1
      end
      plist_buddy_cmd = "/usr/libexec/PlistBuddy -c \"Print :Version\" #{sdk_settings_path}"
      sdk_version = `#{plist_buddy_cmd}`.strip
      sdk_version
    end

    def sdk_version
      @sdk_version ||= begin
        versions = Dir.glob(File.join(platforms_dir, "#{deploy_platform}.platform/Developer/SDKs/#{deploy_platform}[1-9]*.sdk")).sort.map do |path|
          File.basename(path).scan(/#{deploy_platform}(.*)\.sdk/)[0][0]
        end
        if versions.size == 0
          App.fail "Can't find any SDK in `#{platforms_dir}'"
        end
        supported_version = supported_sdk_versions(versions)
        unless supported_version
          # We don't have BridgeSupport data for any of the available SDKs. So
          # use the latest available SDK of which the major version is the same
          # as the latest available BridgeSupport version.

          supported_sdks = supported_versions.map do |version|
            Util::Version.new(version)
          end.sort.reverse
          available_sdks = versions.map do |version|
            Util::Version.new(version)
          end.sort.reverse

          available_sdks.each do |available_sdk|
            major_version = available_sdk.segments.first
            compatible_sdk = supported_sdks.find do |supported_sdk|
              supported_sdk.segments.first == major_version
            end
            if compatible_sdk
              # Never override a user's setting!
              @deployment_target ||= compatible_sdk.to_s
              supported_version = available_sdk.to_s
              App.warn("The available SDK (#{available_sdk}) is newer than " \
                       "the latest available RubyMotion BridgeSupport " \
                       "metadata (#{compatible_sdk}). The `sdk_version` and " \
                       "`deployment_target` settings will be configured " \
                       "accordingly.")
              break
            end
          end
        end
        unless supported_version && !supported_version.empty?
          version_string = xcode_metadata_to_s supported_versions
          App.fail(<<-S)
* ERROR: The requested deployment target SDK is not available or supported by RubyMotion at this time.
Available SDKs: #{versions.join(', ')}
Supported SDKs: #{supported_versions.join(', ')}
#{version_string}
S
        end
        supported_version
      end
    end

    def sdk_build_version(platform)
      @sdk_build_version ||= begin
        sdk_path = sdk(platform)
        plist_path = "#{sdk_path}/System/Library/CoreServices/SystemVersion.plist"
        sdk_build_version = `/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "#{plist_path}" 2>&1`.strip
        if !$?.success?
          `#{locate_binary('xcodebuild')} -version -sdk '#{sdk_path}' ProductBuildVersion`.strip
        else
          sdk_build_version
        end
      end
    end

    def deployment_target
      @deployment_target ||= sdk_version
    end

    def sdk(platform)
      path = File.join(platform_dir(platform), 'Developer/SDKs',
                       platform + sdk_version + '.sdk')
      escape_path(path)
    end

    def frameworks_stubs_objects(platform)
      stubs = []
      deps = frameworks + weak_frameworks
      # Look in the 'bridgesupport_files' method for explanation
      if deps.include?('ApplicationServices') && deployment_target == '10.7' && sdk_version != '10.7'
        deps << 'CoreGraphics'
      end
      deps.uniq.each do |framework|
        stubs_obj = File.join(datadir(sdk_version), platform, "#{framework}_stubs.o")
        stubs << stubs_obj if File.exist?(stubs_obj)
      end
      stubs
    end

    def bridgesupport_files
      @bridgesupport_files ||= begin
        bs_files = []
        deps = ['RubyMotion'] + (frameworks + weak_frameworks).uniq
        # In 10.7 CoreGraphics is a subframework of ApplicationServices. In 10.8 and up
        # it is a system framework too. Since in 10.8 and up we ignore the subframework
        # version of CoreGraphics and do not generate stubs or BS files for it, we have
        # to add them manually if we use the ApplicationServices framework and target 10.7
        if deps.include?('ApplicationServices') && deployment_target == '10.7' && sdk_version != '10.7'
          deps << 'CoreGraphics'
        end
        deps << 'UIAutomation' if spec_mode
        deps.each do |framework|
          bs_path = File.join(datadir(sdk_version), 'BridgeSupport', framework + '.bridgesupport')
          if File.exist?(bs_path)
            bs_files << bs_path
          elsif frameworks.include?(framework)
            self.frameworks.delete(framework)
            App.warn("Could not find .bridgesupport file for framework \"#{framework}\".")
          end
        end
        bs_files
      end
    end

    def default_archs
      h = {}
      platforms.each do |platform|
        h[platform] = Dir.glob(File.join(datadir, platform, '*.bc')).sort.map do |path|
          path.scan(/kernel-(.+).bc$/)[0][0]
        end
      end
      h
    end

    def archs
      @archs ||= default_archs
    end

    def arch_flags(platform)
      archs[platform].map { |x| "-arch #{x}" }.join(' ')
    end

    def common_flags(platform)
      "#{arch_flags(platform)} -isysroot \"#{unescape_path(sdk(platform))}\" -F#{sdk(platform)}/System/Library/Frameworks"
    end

    def cflags(platform, cplusplus)
      optz_level = development? ? '-O0' : '-O3'
      "#{common_flags(platform)} #{optz_level} -fexceptions -fblocks" + (cplusplus ? '' : ' -std=c99') + ' -fmodules'
    end

    def ldflags(platform)
      common_flags(platform) + ' -Wl,-no_pie'
    end

    # @return [String] The application bundle name, excluding extname.
    #
    def bundle_name
      name + (spec_mode ? '_spec' : '')
    end

    # @return [String] The application bundle filename, including extname.
    #
    def bundle_filename
      bundle_name + '.app'
    end

    def versionized_build_dir(platform)
      File.join(build_dir, platform + '-' + deployment_target + '-' + build_mode_name)
    end

    def app_bundle_dsym(platform)
      File.join(versionized_build_dir(platform), bundle_filename + '.dSYM')
    end

    def archive_extension
      raise "not implemented"
    end

    def archive
      File.join(versionized_build_dir(deploy_platform), bundle_name + archive_extension)
    end

    def identifier
      @identifier ||= "com.yourcompany.#{name.gsub(/\s/, '')}"
      spec_mode ? @identifier + '_spec' : @identifier
    end

    def info_plist
      @info_plist
    end

    def dt_info_plist
      {}
    end

    def generic_info_plist
      {
        'BuildMachineOSBuild' => osx_host_build_version,
        'CFBundleDevelopmentRegion' => 'en',
        'CFBundleName' => name,
        'CFBundleDisplayName' => name,
        'CFBundleIdentifier' => identifier,
        'CFBundleExecutable' => name,
        'CFBundleInfoDictionaryVersion' => '6.0',
        'CFBundlePackageType' => 'APPL',
        'CFBundleShortVersionString' => (@short_version || @version),
        'CFBundleSignature' => @bundle_signature,
        'CFBundleVersion' => @version
      }
    end

    # @return [Hash] A hash that contains all the various `Info.plist` data
    #         merged into one hash.
    #
    def merged_info_plist(platform)
      generic_info_plist.merge(dt_info_plist).merge(info_plist)
    end

    # @param [String] platform
    #        The platform identifier that's being build for, such as
    #        `iPhoneSimulator`, `iPhoneOS`, or `MacOSX`.
    #
    #
    # @return [String] A serialized version of the `merged_info_plist` hash.
    #
    def info_plist_data(platform)
      Motion::PropertyList.to_s(merged_info_plist(platform))
    end

    # TODO
    # * Add env vars from user.
    # * Add optional Instruments template to use.
    def profiler_config_plist(platform, args, template, builtin_templates, set_build_env = true)
      working_dir = File.expand_path(versionized_build_dir(platform))
      optional_data = {}

      if template
        template_path = nil
        if File.exist?(template)
          template_path = template
        elsif !builtin_templates.grep(/#{template}/i).empty?
          tmp = template.downcase
          template = profiler_known_templates.find { |path|
            path.downcase == tmp
          }
          template_path = File.expand_path("#{xcode_dir}/../Applications/Instruments.app/Contents/Resources/templates/#{template}.tracetemplate")
        end
        App.fail("Invalid Instruments template path or name.") unless File.exist?(template_path)
        optional_data['XrayTemplatePath'] = template_path
      end

      env = ENV.to_hash
      if set_build_env
        env.merge!({
          'DYLD_FRAMEWORK_PATH' => working_dir,
          'DYLD_LIBRARY_PATH' => working_dir,
          '__XCODE_BUILT_PRODUCTS_DIR_PATHS' => working_dir,
          '__XPC_DYLD_FRAMEWORK_PATH' => working_dir,
          '__XPC_DYLD_LIBRARY_PATH' => working_dir,
        })
      end

      {
        'CFBundleIdentifier' => identifier,
        'absolutePathOfLaunchable' => File.expand_path(app_bundle_executable(platform)),
        'argumentEntries' => (args or ''),
        'workingDirectory' => working_dir,
        'workspacePath' => '', # Normally: /path/to/Project.xcodeproj/project.xcworkspace
        'environmentEntries' => env,
        'optionalData' => {
          'launchOptions' => {
            'architectureType' => 1,
          },
        }.merge(optional_data),
      }
    end

    def profiler_known_templates
      # Get a list of just the templates (ignoring devices)
      list = `#{locate_binary('instruments')} -s 2>&1`.strip.split("\n")
      start = list.index('Known Templates:') + 1
      list = list[start..-1]
      # Only interested in the template (file base) names
      list.map { |line| line.sub(/^\s*"/, '').sub(/",*$/, '') }.map { |path|
        File.basename(path, File.extname(path))
      }
    end

    def profiler_config_device_identifier(device_name, target)
      re = /#{device_name} \(#{target}.*\) \[(.+)\]/
      `#{locate_binary('instruments')} -s 2>&1`.strip.split("\n").each { |line|
        if m = re.match(line)
          return m[1]
        end
      }
    end

    def pkginfo_data
      "AAPL#{@bundle_signature}"
    end

    # Unless a certificate has been assigned by the user, this method tries to
    # find the certificate for the current configuration, based on the platform
    # prefix used in the certificate name and whether or not the current mode is
    # set to release.
    #
    # @param [Array<String>] platform_prefixes
    #        The prefixes used in the certificate name, specified in the
    #        preferred order.
    #
    # @return [String] The name of the certificate.
    #
    def codesign_certificate(*platform_prefixes)
      @codesign_certificate ||= begin
        type = (distribution_mode ? 'Distribution' : 'Developer')
        regex = /(#{platform_prefixes.join('|')}) #{type}/
        certs = Util::CodeSign.identity_names(release?).grep(regex)
        if platform_prefixes.size > 1
          certs = certs.sort do |x, y|
            x_index = platform_prefixes.index(x.match(regex)[1])
            y_index = platform_prefixes.index(y.match(regex)[1])
            x_index <=> y_index
          end
        end
        if certs.size == 0
          App.fail "Cannot find any #{platform_prefixes.join('/')} #{type} " \
                   "certificate in the keychain."
        elsif certs.size > 1
          App.warn "Found #{certs.size} #{platform_prefixes.join('/')} " \
                   "#{type} certificates in the keychain. Set the " \
                   "`codesign_certificate' project setting to explicitly " \
                   "use one of (defaults to the first): #{certs.join(', ')}"
        end
        certs.first
      end
    end

    def gen_bridge_metadata(platform, headers, bs_file, c_flags, exceptions=[])
      # Instead of potentially passing hundreds of arguments to the
      # `gen_bridge_metadata` command, which can lead to a 'too many arguments'
      # error, we list them in a temp file and pass that to the command.
      require 'tempfile'
      headers_file = Tempfile.new('gen_bridge_metadata-headers-list')
      headers.each { |header| headers_file.puts(header) }
      headers_file.close # flush
      # Prepare rest of options.
      sdk_path = self.sdk(local_platform)
      includes = ['-I.'] + headers.map { |header| "-I'#{File.dirname(header)}'" }.uniq
      exceptions = exceptions.map { |x| "\"#{x}\"" }.join(' ')
      c_flags = "#{c_flags} -isysroot '#{sdk_path}' #{bridgesupport_cflags} #{includes.join(' ')}"
      cmd = ("RUBYOPT='' '#{File.join(bindir, 'gen_bridge_metadata')}' #{bridgesupport_flags} --cflags \"#{c_flags}\" --headers \"#{headers_file.path}\" -o '#{bs_file}' #{ "-e #{exceptions}" if exceptions.length != 0}")
      App.info "gen_bridge_metadata", cmd
      if defined?(Bundler)
        Bundler.respond_to?(:with_unbundled_env) ? Bundler.with_unbundled_env { sh(cmd) } : Bundler.with_original_env { sh(cmd) }
      else
        sh(cmd)
      end
    end

    def define_global_env_txt
      "rb_define_global_const(\"RUBYMOTION_ENV\", @\"#{rubymotion_env_value}\");\nrb_define_global_const(\"RUBYMOTION_VERSION\", @\"#{Motion::Version}\");\n"
    end

    def spritekit_texture_atlas_compiler
      path = File.join(xcode_dir, 'usr/bin/TextureAtlas')
      File.exist?(path) ? path : nil
    end

    def assets_bundles
      xcassets_bundles = []
      resources_dirs.each do |dir|
        if File.exist?(dir)
          xcassets_bundles.concat(Dir.glob(File.join(dir, '*.xcassets')).sort)
        end
      end
      xcassets_bundles
    end

    # @return [String] The path to the `Info.plist` file that gets generated by
    #         compiling the asset bundles and contains the data that should be
    #         merged into the final `Info.plist` file.
    #
    def asset_bundle_partial_info_plist_path(platform)
      File.expand_path(File.join(versionized_build_dir(platform), 'AssetCatalog-Info.plist'))
    end

    # @return [String, nil] The path to the asset bundle that contains
    #         application icons, if any.
    #
    def app_icons_asset_bundle
      app_icons_asset_bundles = assets_bundles.map { |b| Dir.glob(File.join(b, '*.appiconset')).sort }.flatten
      if app_icons_asset_bundles.size > 1
        App.warn "Found #{app_icons_asset_bundles.size} app icon sets across all " \
                 "xcasset bundles. Only the first one (alphabetically) " \
                 "will be used."
      end
      app_icons_asset_bundles.sort.first
    end

    # @return [String, nil] The name of the application icon set, without any
    #         extension.
    #
    def app_icon_name_from_asset_bundle
      if bundle = app_icons_asset_bundle
        File.basename(bundle, '.appiconset')
      end
    end

    # Assigns the application icon information, found in the `Info.plist`
    # generated by compiling the asset bundles, to the configuration's `icons`.
    #
    # @return [void]
    #
    def add_images_from_asset_bundles(platform)
      if app_icons_asset_bundle
        path = asset_bundle_partial_info_plist_path(platform)
        if File.exist?(path)
          content = `/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles' "#{path}" 2>&1`.strip
          if $?.success?
            self.icons = content.split("\n")[1..-2].map(&:strip)
          end
        end
      end
    end

    attr_reader :vendor_projects

    def vendor_project(path, type, opts={})
      opts[:force_load] = true unless opts[:force_load] == false
      @vendor_projects << Motion::Project::Vendor.new(path, type, self, opts)
    end

    def unvendor_project(path)
      @vendor_projects.delete_if { |x| x.path == path }
    end

    def xcode_app
      `xcode-select -p`.strip.sub('/Contents/Developer', '')
    end

    def delete_osx_symlink_if_exists
      if File.exist? "#{xcode_app}/Contents/Developer/Toolchains/OSX10.13.xctoolchain"
        fork do
          begin
            `rm -rf #{xcode_app}/Contents/Developer/Toolchains/OSX10.13.xctoolchain`
          rescue
            puts "RubyMotion attempted to delete the following directory, but wasn't able to."
            puts "Please run the following command manually: "
            puts 'rm -rf #{xcode_app}/Contents/Developer/Toolchains/OSX10.13.xctoolchain'
            puts 'You may need to run the command above with `sudo`.'
            raise
          end
        end
      end
    end

    def clean_project
      super
      delete_osx_symlink_if_exists
      @vendor_projects.each { |vendor| vendor.clean(platforms) }
      @targets.each { |target| target.clean }
    end

    attr_accessor :targets

    # App Extensions are required to include a 64-bit slice for App Store
    # submission, so do not exclude `arm64` by default.
    #
    # From https://developer.apple.com/library/prerelease/iOS/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html:
    #
    #  NOTE ABOUT 64-BIT ARCHITECTURE
    #
    #  An app extension target must include the arm64 (iOS) or x86_64
    #  architecture (OS X) in its Architectures build settings or it will be
    #  rejected by the App Store. Xcode includes the appropriate 64-bit
    #  architecture with its "Standard architectures" setting when you create a
    #  new app extension target.
    #
    #  If your containing app target links to an embedded framework, the app
    #  must also include 64-bit architecture or it will be rejected by the App
    #  Store.
    #
    # From https://developer.apple.com/library/ios/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html#//apple_ref/doc/uid/TP40014214-CH21-SW5
    #
    #  A containing app that links to an embedded framework must include the
    #  arm64 (iOS) or x86_64 (OS X) architecture build setting or it will be
    #  rejected by the App Store.
    #
    def target(path, type, opts={})
      unless File.exist?(path)
        App.fail "Could not find target of type '#{type}' at '#{path}'"
      end

      unless archs['iPhoneOS'].include?('arm64')
        App.warn "Device builds of App Extensions and Frameworks are " \
                 "required to have a 64-bit slice for App Store submissions " \
                 "to be accepted."
        App.warn "Your application will now have 64-bit enabled by default, " \
                 "be sure to properly test it on a 64-bit device."
        archs['iPhoneOS'] << 'arm64'
      end

      case type
      when :framework
        opts[:load] = true unless opts[:load] == false
        @targets << Motion::Project::FrameworkTarget.new(path, type, self, opts)
      when :extension
        @targets << Motion::Project::ExtensionTarget.new(path, type, self, opts)
      when :watchapp
        opts = { env: { "WATCHV2" => "1" } }.merge(opts)
        @targets << Motion::Project::WatchTarget.new(path, type, self, opts)
      else
        App.fail("Unsupported target type '#{type}'")
      end
    end

    # Creates a temporary file that lists all the symbols that the application
    # (or extension) should not strip.
    #
    # At the moment these are only symbols that an iOS framework depends on.
    #
    # @return [String] Extra arguments for the `strip` command.
    #
    def strip_args
      args = super
      args << " -x"

      frameworks = targets.select { |t| t.type == :framework }
      required_symbols = frameworks.map(&:required_symbols).flatten.uniq.sort
      unless required_symbols.empty?
        require 'tempfile'
        required_symbols_file = Tempfile.new('required-framework-symbols')
        required_symbols.each { |symbol| required_symbols_file.puts(symbol) }
        required_symbols_file.close
        # Note: If the symbols file contains a symbol that is not present, or
        # is present but undefined (U) in the executable to strip, the command
        # fails. The '-i' option ignores this error.
        args << " -i -s '#{required_symbols_file.path}'"
      end

      args
    end

    def ctags_files
      ctags_files = bridgesupport_files
      ctags_files += vendor_projects.map { |p| Dir.glob(File.join(p.path, '*.bridgesupport')).sort }.flatten
      ctags_files + files.flatten
    end

    def ctags_config_file
      File.join(motiondir, 'data', 'bridgesupport-ctags.cfg')
    end

    def local_repl_port(platform)
      @local_repl_port ||= begin
        ports_file = File.join(versionized_build_dir(platform), 'repl_ports.txt')
        if File.exist?(ports_file)
          File.read(ports_file)
        else
          local_repl_port = TCPServer.new('localhost', 0).addr[1]
          File.open(ports_file, 'w') { |io| io.write(local_repl_port.to_s) }
          local_repl_port
        end
      end
    end
  end
end; end
