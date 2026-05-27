#!/usr/bin/env ruby
# Register the 3 new α.3.1 Swift files into JARVISCompanionApps.xcodeproj.
# Pattern mirrors AuditChainVerify.swift (α.3) registration:
#   - Service-target real file under JARVISMacCockpitService/ → JARVISNativeHTTPServiceReceipt target
#   - Cockpit symlink under JARVISMacCockpit/ → JARVISMacCockpit target
require 'xcodeproj'

PROJ_PATH = 'apple_native/JARVISCompanionApps.xcodeproj'
proj = Xcodeproj::Project.open(PROJ_PATH)

cockpit_target = proj.targets.find { |t| t.name == 'JARVISMacCockpit' }
service_target = proj.targets.find { |t| t.name == 'JARVISNativeHTTPServiceReceipt' }
raise 'targets not found' unless cockpit_target && service_target

cockpit_group = proj.main_group.recursive_children_groups.find { |g| g.path == 'JARVISMacCockpit' && g.parent == proj.main_group } \
              || proj.main_group['JARVISMacCockpit']
service_group = proj.main_group.recursive_children_groups.find { |g| g.path == 'JARVISMacCockpitService' && g.parent == proj.main_group } \
              || proj.main_group['JARVISMacCockpitService']
raise 'groups not found' unless cockpit_group && service_group

FILES = %w[EndocrineCABIClient.swift SFAppendArmerXPCProtocol.swift SFAppendArmClient.swift]

def already?(target, basename)
  src = target.build_phases.find { |p| p.is_a?(Xcodeproj::Project::Object::PBXSourcesBuildPhase) }
  src.files.any? { |f| f.file_ref && f.file_ref.path.to_s == basename }
end

FILES.each do |name|
  # service ref
  unless already?(service_target, name)
    ref = service_group.new_reference(name)
    ref.last_known_file_type = 'sourcecode.swift'
    service_target.source_build_phase.add_file_reference(ref)
    puts "service: added #{name}"
  end
  # cockpit ref
  unless already?(cockpit_target, name)
    ref = cockpit_group.new_reference(name)
    ref.last_known_file_type = 'sourcecode.swift'
    cockpit_target.source_build_phase.add_file_reference(ref)
    puts "cockpit: added #{name}"
  end
end

proj.save
puts 'saved'
