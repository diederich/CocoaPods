module Pod
  class Installer

    # This class is responsible of linking the linkable pods into the
    # corresponding targets in the users project and of adding these pods projects
    # to the workspace, so that Xcode' s build system can find them.
    #
    class LinkedDependenciesInstaller

      def initialize (podfile, pods_by_target)
        @podfile = podfile
        @pods_by_target = pods_by_target
      end

      def linked_specs_by_target
        @linked_specs_by_target ||= begin
          hash = {}
          @pods_by_target.each { |target, pods|
            linked_specs = pods.collect { |pod| pod.specifications.select {|spec| spec.xcodeproj.present? } }.flatten.uniq
            hash[target] = linked_specs unless linked_specs.empty?
          }
          hash
        end
      end

      def linked_specs
        linked_specs_by_target.values.flatten
      end

      def add_projects_to_workspace(pods,sandbox)
        pods.each do |pod|
          pod.specifications.each do |spec|
            if spec.xcodeproj.present?
              lib_project = ( pod.root + spec.xcodeproj[:project]).relative_path_from(workspace_path.dirname).to_s
              UI.message "project: "+lib_project.to_s
              workspace << lib_project unless workspace.include?(lib_project)
            end
          end
        end
        workspace.save_as(workspace_path)
      end

      def workspace
        @workspace ||= Xcodeproj::Workspace.new_from_xcworkspace(workspace_path)
      end

      def workspace_path
        @podfile.workspace || raise(Informative, "Could not automatically select an Xcode workspace. " \
                                               "Specify one in your Podfile.")
      end

      def add_libraries_to_targets
        linked_specs_by_targets = linked_specs_by_target
        linked_specs_by_targets.each do |target_definition, specs|

        project = target_definition.user_project
        user_project = project.project

        targets = link_targets_in_definition(target_definition, user_project)
        frameworks = user_project.frameworks_group

        specs.each do |spec|

          pod = @pods_by_target[target_definition].find { |pod| pod.specifications.include? spec }

            pod_project_path = File.join(pod.root,spec.xcodeproj[:project])
            pod_project = Xcodeproj::Project.new(pod_project_path)
            raise(Informative, "Could not open project #{spec.xcodeproj[:project]}, specified in #{spec.defined_in_file} ") if pod_project.nil?

            lib_target = pod_project.targets.find { |target| target.name == spec.xcodeproj[:library_target]}
            raise(Informative, "Could not find target #{spec.xcodeproj[:library_target]} in project #{spec.xcodeproj[:project]}, specified in #{spec.defined_in_file} ") if lib_target.nil?

            lib_name = lib_target.product_reference.path

            resource_name = nil;
            unless spec.xcodeproj[:resource_target].nil?
              resource_target = pod_project.targets.find { |target| target.name == spec.xcodeproj[:resource_target]}
              raise(Informative, "Could not find target #{spec.xcodeproj[:resource_target]} in project #{spec.xcodeproj[:project]}, specified in #{spec.defined_in_file} ") if resource_target.nil?
              resource_name = resource_target.product_reference.path
            end

            if targets.present?

              library = frameworks.children.find {|file| file.name == lib_name}
              library ||= begin
                library_ref = frameworks.new_file(lib_name)
                library_ref.include_in_index = '0'
                library_ref.source_tree = 'BUILT_PRODUCTS_DIR'
                library_ref.explicit_file_type = library_ref.last_known_file_type
                library_ref.last_known_file_type = nil
                library_ref
              end
              targets.each do |link_target|
                unless link_target.frameworks_build_phase.files.any? { |build_file| build_file.file_ref.path == lib_name }
                  link_target.frameworks_build_phase.add_file_reference(library)
                end
              end
              if resource_name.present?

                resource_bundle = frameworks.children.find {|file| file.name == resource_name}
                resource_bundle ||= begin
                  resource_bundle_ref = frameworks.new_file(resource_name)
                  resource_bundle_ref.include_in_index = '0'
                  resource_bundle_ref.source_tree = 'BUILT_PRODUCTS_DIR'
                  resource_bundle_ref.explicit_file_type = resource_bundle_ref.last_known_file_type
                  resource_bundle_ref.last_known_file_type = nil
                  resource_bundle_ref
                end

                targets.each do |link_target|
                  copy_files = link_target.copy_files_build_phases.find { |copy_phase| copy_phase.name == "Copy Pod Resource bundles" }
                  copy_files ||= link_target.new_copy_files_build_phase("Copy Pod Resource bundles")
                  unless copy_files.files.any? { |build_file| build_file.file_ref.path == resource_name }
                    copy_files.add_file_reference(resource_bundle)
                  end
                end
              end
            end
          end
          user_project.save_as(project.path)
        end
      end

      def link_targets_in_definition(target_definition, user_project)

        targets = begin
          if link_with = target_definition.link_with
            # Find explicitly linked targets.
            user_project.targets.select do |target|
              link_with.include? target.name
            end
          elsif target_definition.name != :default
            # Find the target with the matching name.
            target = user_project.targets.find { |target| target.name == target_definition.name.to_s }
            raise Informative, "Unable to find a target named `#{target_definition.name.to_s}'" unless target
            [target]
          else
            # Default to the first, which in a simple project is probably an app target.
            [user_project.targets.first]
          end
        end
        targets
      end

    end
  end
end