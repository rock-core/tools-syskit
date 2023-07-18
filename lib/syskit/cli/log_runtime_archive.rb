# frozen_string_literal: true

require "archive/tar/minitar"

module Syskit
    module CLI
        # Implementation of the `syskit log-runtime-archive` tool
        #
        # The tool archives Syskit log directories into tar archives in realtime,
        # compressing files using zstd
        #
        # It depends on the syskit instance using log rotation
        module LogRuntimeArchive
            # Find all dataset-looking folders within a root log folder
            def self.find_all_dataset_folders(root_dir)
                candidates = root_dir.enum_for(:each_entry).map do |child|
                    next unless /^\d{8}\-\d{4}(\.\d+)?$/.match?(child.basename.to_s)

                    child = (root_dir / child)
                    next unless child.directory?

                    child if (child / "info.yml").file?
                end

                candidates.compact.sort_by { _1.basename.to_s }
            end

            # Safely add an entry into an archive, compressing it with zstd
            #
            # @return [Boolean] true if the file was added successfully, false otherwise
            def self.add_to_archive(archive_io, child_path)
                puts "adding #{child_path}"
                stat = child_path.stat

                start_pos = archive_io.tell
                write_initial_header(archive_io, child_path, stat)
                data_pos = archive_io.tell
                exit_status = write_compressed_data(child_path, archive_io)

                if exit_status.success?
                    add_to_archive_commit(
                        archive_io, child_path, start_pos, data_pos, stat
                    )
                    child_path.unlink
                    true
                else
                    add_to_archive_rollback(archive_io, start_pos)
                    false
                end
            rescue Exception => e # rubocop:disable Lint/RescueException
                Roby.display_exception(STDOUT, e)
                add_to_archive_rollback(archive_io, start_pos) if start_pos
                false
            end

            # Finalize appending a file in the archive
            def self.add_to_archive_commit(
                archive_io, child_path, start_pos, data_pos, stat
            )
                data_size = archive_io.tell - data_pos
                write_padding(data_size, archive_io)

                # Update header
                archive_io.seek(start_pos, IO::SEEK_SET)
                write_final_header(archive_io, child_path, stat, data_size)
                archive_io.seek(0, IO::SEEK_END)
            end

            # Revert the addition of a file in the archive, after an error
            def self.add_to_archive_rollback(archive_io, start_pos)
                archive_io.truncate(start_pos)
                archive_io.seek(start_pos, IO::SEEK_SET)
            end

            # Write a tar block header without the data size
            def self.write_initial_header(archive_io, child_path, stat)
                write_header(
                    archive_io,
                    "#{child_path.basename}.zst",
                    { mode: 0o644, uid: stat.uid, gid: stat.gid,
                      mtime: stat.mtime, size: 0 }
                )
            end

            # Write the final tar block header at the given position
            def self.write_final_header(archive_io, child_path, stat, size)
                write_header(
                    archive_io,
                    "#{child_path.basename}.zst",
                    { mode: 0o644, uid: stat.uid, gid: stat.gid,
                      mtime: stat.mtime, size: size }
                )
            end

            # Compress data and append it to the archive
            def self.write_compressed_data(child_path, archive_io)
                _, exit_status = child_path.open("r") do |io|
                    zstd_transfer_r, zstd_transfer_w = IO.pipe
                    pid = Process.spawn("zstd", "--stdout", in: io, out: zstd_transfer_w)
                    zstd_transfer_w.close
                    IO.copy_stream(zstd_transfer_r, archive_io)
                    Process.waitpid2(pid)
                end
                exit_status
            end

            # Write necessary padding (tar requires multiples of 512 bytes)
            def self.write_padding(size, io)
                # Move to end, compute actual size, pad to 512 bytes blocks
                remainder = (size + 511) / 512 * 512 - size
                io.write("\0" * remainder)
            end

            # Archive the given dataset
            #
            # @param [IO] archive_io the IO of the target archive
            # @param [Pathname] path path to the dataset folder
            # @param [Boolean] full whether we're arching the complete dataset (true),
            #   or only the files that we know are not being written to (for log
            #   directories of running Syskit instances)
            def self.archive_dataset(archive_io, path, full:)
                puts "Archiving dataset #{path} in #{full ? "full" : "partial"} mode"
                candidates = path.enum_for(:each_entry).map { path / _1 }
                candidates = archive_partial_filter_candidates(candidates) unless full

                candidates.each do |child_path|
                    add_to_archive(archive_io, child_path)
                end
            end

            # Filters all candidates for archiving to return the ones relevant for a
            # partial archive (i.e. excluding files that are being written to)
            #
            # @param [Array<Pathname>] candidates
            # @return [Array<Pathname>] files that should be archived
            def self.archive_partial_filter_candidates(candidates)
                per_file_and_idx = filter_and_group_pocolog_files(candidates)
                per_file_and_idx.each_value.flat_map do |logs|
                    logs.delete(logs.keys.max)
                    logs.values
                end
            end

            # Filter the pocolog files from the given candidates and sort them
            # by basename and log index
            #
            # @param [Array<Pathname>] candidates
            # @return [{String=>{Integer=>Pathname}}]
            def self.filter_and_group_pocolog_files(candidates)
                candidates.each_with_object({}) do |path, h|
                    name = path.basename.to_s
                    if (m = /\.(\d+)\.log$/.match(name))
                        per_file = (h[m.pre_match] ||= {})
                        per_file[Integer(m[1])] = path
                    end
                end
            end

            # Iterate over all datasets in a Roby log root folder and archive them
            #
            # The method assumes the last dataset is the current one (i.e. the running
            # one), and will only archive already rotated files.
            #
            # @param [Pathname] root_dir the log root folder
            # @param [Pathname] target_dir the folder in which to save the
            #   archived datasets
            def self.process_root_folder(root_dir, target_dir)
                candidates = find_all_dataset_folders(root_dir)
                running = candidates.last
                candidates.each do |child|
                    archive_path = target_dir / "#{child.basename}.tar"
                    mode =
                        if archive_path.exist?
                            "r+"
                        else
                            "w"
                        end

                    archive_path.open(mode) do |archive_io|
                        archive_io.seek(0, IO::SEEK_END)
                        archive_dataset(archive_io, child, full: child != running)
                    end
                end
            end

            extend Archive::Tar::Minitar::ByteSize

            # Copy a tar header (copied from minitar)
            def self.write_header(io, long_name, header)
                short_name, prefix, needs_long_name = split_name(long_name)

                if needs_long_name
                    long_name_header = {
                        prefix: "",
                        name: Archive::Tar::Minitar::PosixHeader::GNU_EXT_LONG_LINK,
                        typeflag: "L",
                        size: long_name.length,
                        mode: 0
                    }
                    io.write(Archive::Tar::Minitar::PosixHeader.new(long_name_header))
                    io.write(long_name)
                    io.write("\0" * (512 - (long_name.length % 512)))
                end

                new_header = header.merge({ name: short_name, prefix: prefix })
                io.write(Archive::Tar::Minitar::PosixHeader.new(new_header))
            end

            # Process a file name to determine whether it should use the GNU
            # long file extension. Copied from minitar
            def self.split_name(name) # rubocop:disable Metrics/AbcSize
                if bytesize(name) <= 100
                    prefix = ""
                else
                    parts = name.split(%r{\/})
                    newname = parts.pop

                    nxt = ""

                    loop do
                        nxt = parts.pop || ""
                        break if bytesize(newname) + 1 + bytesize(nxt) >= 100

                        newname = "#{nxt}/#{newname}"
                    end

                    prefix = (parts + [nxt]).join("/")
                    name = newname
                end

                [name, prefix, (bytesize(name) > 100 || bytesize(prefix) > 155)]
            end
        end
    end
end
