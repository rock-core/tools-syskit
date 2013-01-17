module Syskit
    module GUI
        # A model that lists Ruby modules that match a given predicate (given at
        # construction time)
        class RubyModuleModel < Qt::AbstractItemModel
            ModuleInfo = Struct.new :id, :name, :this, :parent, :children, :row, :types
            TypeInfo = Struct.new :name, :priority, :color

            attr_reader :predicate
            attr_reader :id_to_module
            attr_reader :module_info
            attr_reader :filtered_out_modules
            attr_reader :type_info

            def initialize(type_info = Hash.new, &predicate)
                @predicate = predicate || proc { true }
                @type_info = type_info

                @id_to_module = []
                @module_info = Hash.new
                @filtered_out_modules = Set.new

                info = discover_module(Object)
                info.id = id_to_module.size
                info.name = "Syskit Models"
                update_module_type_info(info)
                info.row = 0
                id_to_module << info

                super()
            end

            def update_module_type_info(info)
                types = info.types.to_set
                info.children.each do |child_info|
                    types |= child_info.types.to_set
                end
                info.types = types.to_a.sort_by do |type|
                    type_info[type].priority
                end.reverse
            end

            def discover_module(mod, stack = Array.new)
                stack.push mod

                children_modules = mod.constants.map do |child_name|
                    next if !mod.const_defined_here?(child_name)
                    child_mod = mod.const_get(child_name)
                    next if !child_mod.kind_of?(Module)
                    next if filtered_out_modules.include?(child_mod)
                    next if stack.include?(child_mod)
                    [child_name, child_mod]
                end.compact.sort_by(&:first)

                children = []
                mod_info = ModuleInfo.new(nil, nil, mod, nil, children, nil, Set.new)

                children_modules.each do |child_name, child_mod|
                    if info = discover_module(child_mod, stack)
                        info.id = id_to_module.size
                        info.name = child_name.to_s
                        info.parent = mod_info
                        info.row = children.size
                        children << info
                        id_to_module << info
                    else
                        filtered_out_modules << child_mod
                    end
                end

                is_needed = predicate.call(mod)
                if is_needed
                    mod.ancestors.each do |ancestor|
                        if type_info.has_key?(ancestor)
                            mod_info.types << ancestor
                        end
                    end
                end
                update_module_type_info(mod_info)

                if !children.empty? || is_needed
                    mod_info
                end
            ensure stack.pop
            end

            def headerData(section, orientation, role)
                if role == Qt::DisplayRole && section == 0
                    Qt::Variant.new("Syskit Models")
                else Qt::Variant.new
                end
            end

            def data(index, role)
                if info = info_from_index(index)
                    if role == Qt::DisplayRole
                        return Qt::Variant.new(info.name)
                    elsif role == Qt::UserRole
                        types = info.types.map do |type|
                            type_info[type].name
                        end.sort.join(",")
                        return Qt::Variant.new(types)
                    end
                end
                return Qt::Variant.new
            end

            def index(row, column, parent)
                if info = info_from_index(parent)
                    create_index(row, column, info.children[row].id)
                else
                    Qt::ModelIndex.new
                end
            end

            def parent(child)
                if info = info_from_index(child)
                    if info.parent
                        return create_index(info.parent.row, 0, info.parent.id)
                    end
                end
                Qt::ModelIndex.new
            end

            def rowCount(parent)
                if info = info_from_index(parent)
                    if !info.children
                        pp info
                    end
                    info.children.size
                else 0
                end
            end

            def columnCount(parent)
                return 1
            end

            def info_from_index(index)
                if !index.valid?
                    return id_to_module.last
                else
                    id_to_module[index.internal_id >> 1]
                end
            end
        end
    end
end

