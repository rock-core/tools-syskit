# frozen_string_literal: true

import_types_from "std"

module SyskitUnitTests
    module Compositions
        class ReloadRubyTask < Syskit::RubyTaskContext
            output_port "test", "/int32_t"
        end
    end
end
