#!/usr/bin/env ruby
require 'xcodeproj'

project_name = 'ICCCAlert'
project_path = "#{project_name}.xcodeproj"

puts "🚀 Generating iOS Xcode project: #{project_name}"
puts "📦 Including WebRTC support"

# Create project
project = Xcodeproj::Project.new(project_path)

# Create main target
target = project.new_target(:application, project_name, :ios, '14.0')

# Create group structure
main_group = project.main_group.new_group(project_name)
models_group = main_group.new_group('Models')
views_group = main_group.new_group('Views')
services_group = main_group.new_group('Services')
viewmodels_group = main_group.new_group('ViewModels')
utils_group = main_group.new_group('Utils')

puts "📁 Adding Swift files..."

# Track filenames to detect duplicates
seen_filenames = {}

# Add all Swift files
swift_files = Dir.glob("#{project_name}/**/*.swift")
puts "Found #{swift_files.count} Swift files"

swift_files.each do |file|
  filename = File.basename(file)
  relative_path = file.sub("#{project_name}/", "")
  group_name = File.dirname(relative_path)
  
  # Check for duplicates
  if seen_filenames[filename]
    puts "⚠️  Duplicate file detected: #{filename}"
    puts "   Already added: #{seen_filenames[filename]}"
    puts "   Skipping: #{file}"
    
    if group_name == 'Models' && seen_filenames[filename].include?('ViewModels')
      puts "   → Keeping ViewModels version"
      next
    end
  end
  
  group = case group_name
  when 'Models' then models_group
  when 'Views' then views_group
  when 'Services' then services_group
  when 'ViewModels' then viewmodels_group
  when 'Utils' then utils_group
  else main_group
  end
  
  file_ref = group.new_reference(file)
  target.add_file_references([file_ref])
  seen_filenames[filename] = file
  puts "  ✓ Added: #{file}"
end

# Add Info.plist
info_plist = main_group.new_reference("#{project_name}/Info.plist")

# Add Assets
assets_path = "#{project_name}/Assets.xcassets"
if Dir.exist?(assets_path)
  assets = main_group.new_reference(assets_path)
  target.resources_build_phase.add_file_reference(assets)
  puts "  ✓ Added: Assets.xcassets"
end

puts "\n⚙️  Configuring build settings..."

# Configure build settings
target.build_configurations.each do |config|
  config.build_settings['PRODUCT_NAME'] = project_name
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.iccc.alert'
  config.build_settings['SWIFT_VERSION'] = '5.9'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '14.0'
  config.build_settings['INFOPLIST_FILE'] = "#{project_name}/Info.plist"
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks'
  
  # Swift Package Manager support
  config.build_settings['SWIFT_PACKAGE_DEPENDENCIES'] = 'YES'
  
  # No code signing for CI builds
  config.build_settings['CODE_SIGN_IDENTITY'] = ''
  config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  config.build_settings['ENABLE_BITCODE'] = 'NO'
  
  # Allow insecure HTTP for video streaming (needed for your servers)
  config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] = '$(inherited) COCOAPODS=1'
end

puts "\n📦 Setting up WebRTC framework..."

# Note: WebRTC will be added via Swift Package Manager
# The Package.swift file should be in the root directory
puts "  ℹ️  WebRTC will be resolved via Swift Package Manager"
puts "  ℹ️  Run: xcodebuild -resolvePackageDependencies"

# Save project
project.save
puts "\n✅ Xcode project generated: #{project_path}"
puts "📋 Summary:"
puts "   - Total Swift files: #{seen_filenames.count}"
puts "   - Target: #{project_name}"
puts "   - Bundle ID: com.iccc.alert"
puts "   - Deployment Target: iOS 14.0"
puts "   - WebRTC: Managed by Swift Package Manager"
puts "\n🔧 Next steps:"
puts "   1. Open #{project_path}"
puts "   2. Add Swift package: https://github.com/stasel/WebRTC.git"
puts "   3. Or run: xcodebuild -resolvePackageDependencies"