# frozen_string_literal: true

module Syskit
    module Coordination
        # Extension module for Roby::Transaction
        module TransactionExtension
            # Hook called to apply the modifications stored in self to the
            # underlying plan
            #
            # @see Roby::Transaction#apply_modifications_to_plan
            def apply_modifications_to_plan
                super

                # We add the data monitoring tables to the underlying plan. We
                # have to make sure to only add tables that are not tied to a
                # fault response table, as those are already passed on by the
                # table itself
                from_fault_response_table = Set.new
                active_fault_response_tables.each do |tbl|
                    from_fault_response_table |= tbl.data_monitoring_tables.to_set
                end
                data_monitoring_tables.each do |tbl|
                    unless from_fault_response_table.include?(tbl)
                        plan.use_data_monitoring_table tbl.model, tbl.arguments
                    end
                end
            end
        end
    end
end

Roby::Transaction.class_eval do
    prepend Syskit::Coordination::TransactionExtension
end
