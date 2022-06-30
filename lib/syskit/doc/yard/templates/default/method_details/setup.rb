# frozen_string_literal: true

def init
    super
    sections.place(:profile_definition_graphs).after(:header)
end

def profile_definition_graphs
    return unless object[:syskit]
    return unless (@profile_definition_graphs = object.syskit.profile_definition_graphs)
    return if @profile_definition_graphs.empty?

    @profile_definition_graphs = @profile_definition_graphs.transform_values do |data|
        next(data) if data["error"]

        basename = File.basename(data)
        dirname = File.basename(File.dirname(data))
        File.join(dirname, basename)
    end

    erb(:profile_definition_graphs)
end
