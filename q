diff --git a/lib/syskit/actions/profile.rb b/lib/syskit/actions/profile.rb
index 2c785bb..c61bf0d 100644
--- a/lib/syskit/actions/profile.rb
+++ b/lib/syskit/actions/profile.rb
@@ -77,6 +77,7 @@ def use_profile(profile)
             #
             # @return [InstanceRequirements] the added instance requirement
             def define(name, requirements)
+                STDOUT.puts "I'm here in define"
                 resolved = dependency_injection_context.
                     current_state.direct_selection_for(requirements) || requirements
                 definitions[name] = resolved.to_instance_requirements
@@ -208,7 +209,9 @@ def profile(name, &block)
                     const_set(name, profile)
                 end
                 Profile.profiles << profile
+                STDOUT.puts "Location: #{block.source_location}"
                 profile.instance_eval(&block)
+                STDOUT.puts "Finished"
             end
         end
         Module.include ProfileDefinitionDSL
diff --git a/lib/syskit/dependency_injection.rb b/lib/syskit/dependency_injection.rb
index 00741a1..02f719e 100644
--- a/lib/syskit/dependency_injection.rb
+++ b/lib/syskit/dependency_injection.rb
@@ -174,6 +174,7 @@ def has_selection_for?(name)
             def self.normalize_selection(selection)
                 normalized = Hash.new
                 selection.each do |key, value|
+                    STDOUT.puts "Key/Value: #{key}, #{value}"
                     # 'key' must be one of String, Component or DataService
                     if !key.respond_to?(:to_str) &&
                         !key.kind_of?(Models::DataServiceModel) &&
diff --git a/lib/syskit/models/component.rb b/lib/syskit/models/component.rb
index 6d4859e..2170092 100644
--- a/lib/syskit/models/component.rb
+++ b/lib/syskit/models/component.rb
@@ -217,6 +217,8 @@ def port_mappings_for(model)
             def find_data_service_from_type(type)
                 candidates = find_all_data_services_from_type(type)
                 if candidates.size > 1
+                    STDOUT.puts candidates
+
                     raise AmbiguousServiceSelection.new(self, type, candidates),
                         "multiple services match #{type.short_name} on #{short_name}"
                 elsif candidates.size == 1
