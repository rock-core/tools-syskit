require 'roby/app/gen'
class CmpGenerator < Roby::App::GenModelClass
    def initialize(runtime_args, runtime_options = Hash.new)
        @model_type = 'blueprints'
        super
    end
end

