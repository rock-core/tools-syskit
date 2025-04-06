# frozen_string_literal: true

module Syskit
    module Runtime
        module Server
            # Custom write-only file system that detects collision between files
            class WriteOnlyDiskFileSystem
                include Ftpd::DiskFileSystem::Base
                include Ftpd::DiskFileSystem::Mkdir
                include Ftpd::DiskFileSystem::FileWriting
                include Ftpd::DiskFileSystem::Rename
                include Ftpd::Error
                include Ftpd::TranslateExceptions

                def initialize(data_dir)
                    # Ftpd base methods expect data_dir to be a string
                    unless data_dir.respond_to?(:to_s)
                        raise ArgumentError,
                              "data_dir should be convertible into string"
                    end

                    set_data_dir data_dir.to_s
                end

                # Write a file to disk if it does not already exist.
                # @param ftp_path [String] The virtual path
                # @param stream [Ftpd::Stream] Stream that contains the data to write
                #
                # Called for:
                # * STOR
                # * STOU
                #
                # If missing, then these commands are not supported.

                def write(ftp_path, stream)
                    full_path = File.join(@data_dir, ftp_path)
                    final_path = File.join(
                        File.dirname(full_path),
                        File.basename(full_path, ".partial")
                    )
                    error "Already exists", 550 if File.exist?(final_path)

                    write_file ftp_path, stream, "wb"
                end
                translate_exceptions :write
            end
        end
    end
end
