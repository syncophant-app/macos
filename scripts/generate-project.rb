#!/usr/bin/env ruby
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.new(File.join(root, 'Syncophant.xcodeproj'))
project.root_object.attributes['LastUpgradeCheck'] = '2700'
package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '.'
project.root_object.package_references << package
sparkle = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
sparkle.repositoryURL = 'https://github.com/sparkle-project/Sparkle'
sparkle.requirement = { 'kind' => 'exactVersion', 'version' => '2.10.1' }
project.root_object.package_references << sparkle

def product(project, target, package, name)
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package
  dependency.product_name = name
  target.package_product_dependencies << dependency
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
end

app = project.new_target(:application, 'Syncophant', :osx, '26.0')
provider = project.new_target(:app_extension, 'SyncophantProvider', :osx, '26.0')
agent = project.new_target(:command_line_tool, 'SyncophantAgentRendezvous', :osx, '26.0')
agent_group = project.main_group.new_group('SSH Agent Rendezvous')
%w[Sources/AgentRendezvous/main.swift Sources/PlatformShared/SSHAgentXPCProtocol.swift Sources/PlatformShared/SSHAgentRendezvous.swift].each do |path|
  agent.add_file_references([agent_group.new_file(path)])
end
agent.build_configurations.each do |build|
  settings = build.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'app.syncophant.mac.agent-rendezvous'
  settings['SWIFT_VERSION'] = '6.0'
  settings['MACOSX_DEPLOYMENT_TARGET'] = '26.0'
  settings['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
  settings['CODE_SIGN_INJECT_BASE_ENTITLEMENTS'] = 'NO' if build.name == 'Release'
  settings['SKIP_INSTALL'] = 'YES'
  settings['CODE_SIGN_STYLE'] = ENV['SYNCOPHANT_TEAM_ID'] ? 'Manual' : 'Automatic'
  settings['CODE_SIGN_IDENTITY'] = ENV.fetch('SYNCOPHANT_SIGNING_IDENTITY', ENV['SYNCOPHANT_DISTRIBUTION'] == '1' ? 'Developer ID Application' : 'Apple Development')
  settings['OTHER_CODE_SIGN_FLAGS'] = ['--identifier', 'app.syncophant.mac.agent-rendezvous']
  settings['DEVELOPMENT_TEAM'] = ENV['SYNCOPHANT_TEAM_ID'] if ENV['SYNCOPHANT_TEAM_ID']
end

[[app, %w[SyncophantApp PlatformShared], 'App', 'app.syncophant.mac'],
 [provider, %w[FileProviderExtension PlatformShared], 'Provider', 'app.syncophant.mac.provider']].each do |target, dirs, config, identifier|
  group = project.main_group.new_group(target.name)
  dirs.each do |dir|
    Dir.glob(File.join(root, 'Sources', dir, '**', '*.swift')).sort.each do |path|
      target.add_file_references([group.new_file(path.delete_prefix(root + '/'))])
    end
  end
  helper = group.new_file('.deps/bin/syncophant-crypt')
  target.resources_build_phase.add_file_reference(helper)
  if target == app
    resources = project.main_group.new_group('Acknowledgements')
    Dir.glob(File.join(root, '.deps', 'notices', '*.txt')).sort.each do |path|
      target.resources_build_phase.add_file_reference(resources.new_file(path.delete_prefix(root + '/')))
    end
    icon = project.main_group.new_file('Assets/AppIcon.icns')
    target.resources_build_phase.add_file_reference(icon)
    target.resources_build_phase.add_file_reference(project.main_group.new_file('Assets/MenuBarIcon.svg'))
    target.resources_build_phase.add_file_reference(resources.new_file('LICENSE'))
    target.resources_build_phase.add_file_reference(resources.new_file('Config/Library-LICENSE.txt'))
    %w[docs/licenses/AMSMB2-LGPL-2.1.txt scripts/crypt-helper/THIRD_PARTY_NOTICES.txt].each do |path|
      target.resources_build_phase.add_file_reference(resources.new_file(path))
    end
  end
  product(project, target, package, 'CoreKit')
  product(project, target, package, 'HetznerKit') if target == app
  product(project, target, sparkle, 'Sparkle') if target == app
  target.build_configurations.each do |build|
    settings = build.build_settings
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = identifier
    settings['INFOPLIST_FILE'] = "Config/#{config}-Info.plist"
    settings['CODE_SIGN_ENTITLEMENTS'] = "Config/#{config}.entitlements"
    settings['CODE_SIGN_STYLE'] = 'Automatic'
    if ENV['SYNCOPHANT_TEAM_ID']
      settings['CODE_SIGN_STYLE'] = 'Manual'
      settings['DEVELOPMENT_TEAM'] = ENV['SYNCOPHANT_TEAM_ID']
      distribution = ENV['SYNCOPHANT_DISTRIBUTION'] == '1'
      settings['CODE_SIGN_IDENTITY'] = ENV.fetch('SYNCOPHANT_SIGNING_IDENTITY', distribution ? 'Developer ID Application' : 'Apple Development')
      settings['PROVISIONING_PROFILE_SPECIFIER'] = if distribution
        target == app ? 'Syncophant Developer ID' : 'Syncophant File Provider Developer ID'
      else
        target == app ? 'Syncophant Mac Development' : 'Syncophant Mac File Provider Development'
      end
    end
    settings['SWIFT_VERSION'] = target == app ? '6.0' : '5.0'
    settings['MACOSX_DEPLOYMENT_TARGET'] = '26.0'
    # Release builds override both from the tag (scripts/build.sh).
    settings['MARKETING_VERSION'] = '0.1.0'
    settings['CURRENT_PROJECT_VERSION'] = '1'
    settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
    settings['CODE_SIGN_INJECT_BASE_ENTITLEMENTS'] = 'NO' if build.name == 'Release'
    settings['ENABLE_DEBUG_DYLIB'] = 'NO'
    settings['GENERATE_INFOPLIST_FILE'] = 'NO'
    settings['SWIFT_STRICT_CONCURRENCY'] = 'complete'
    settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/../Frameworks', '@executable_path/../../../../Frameworks']
    settings['SWIFT_INCLUDE_PATHS'] = ['$(inherited)', '$(SRCROOT)/.deps/include', '/opt/homebrew/opt/libssh2/include', '/usr/local/opt/libssh2/include']
    settings['HEADER_SEARCH_PATHS'] = ['$(inherited)', '$(SRCROOT)/.deps/include', '/opt/homebrew/opt/libssh2/include', '/usr/local/opt/libssh2/include']
    settings['LIBRARY_SEARCH_PATHS'] = ['$(inherited)', '$(SRCROOT)/.deps/lib']
    settings['OTHER_LDFLAGS'] = ['$(inherited)', '-lssh2', '-lcrypto', '-lz']
    settings['SKIP_INSTALL'] = target == app ? 'NO' : 'YES'
    settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES' if target == provider
    settings['COMBINE_HIDPI_IMAGES'] = 'YES'
  end
end

app.add_dependency(provider)
app.add_dependency(agent)
agent_embed = app.new_copy_files_build_phase('Embed SSH Agent Rendezvous')
agent_embed.dst_subfolder_spec = '6'
agent_file = agent_embed.add_file_reference(agent.product_reference)
agent_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy'] }
launch_embed = app.new_copy_files_build_phase('Embed SSH Agent LaunchAgent')
launch_embed.dst_subfolder_spec = '1'
launch_embed.dst_path = 'Contents/Library/LaunchAgents'
launch_embed.add_file_reference(project.main_group.new_file('Config/app.syncophant.mac.agent-rendezvous.plist'))
embed = app.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
file = embed.add_file_reference(provider.product_reference)
file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.save_as(File.join(root, 'Syncophant.xcodeproj'), 'Syncophant', true)
provider_scheme = Xcodeproj::XCScheme.new
provider_scheme.add_build_target(provider)
provider_scheme.save_as(File.join(root, 'Syncophant.xcodeproj'), 'SyncophantProvider', true)
project.save
puts 'Generated Syncophant.xcodeproj'
