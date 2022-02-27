# frozen_string_literal: true

module Syskit
    module RobyApp
        module REST
            # Endpoints to manage deployments
            #
            # Usually available under /syskit/jobs
            class Jobs < Grape::API
                params do
                    optional :since, type: Integer
                end
                get "/" do
                    jobs = roby_interface.jobs
                    if params[:since]
                        jobs.delete_if do |_, _, job_task|
                            job_task.job_id <= params[:since]
                        end

                        if jobs.empty?
                            status 304 # not modified
                            return
                        end
                    end

                    jobs_json = jobs.map do |status, placeholder, job|
                        job_to_json(status, placeholder, job)
                    end
                    { jobs: jobs_json }
                end

                helpers do
                    def job_to_json(status, placeholder, job)
                        arguments = job&.action_arguments || []
                        {
                            id: job.job_id,
                            name: job&.action_model&.name,
                            arguments: arguments.map(&:to_s)
                        }
                    end
                end
            end
        end
    end
end
