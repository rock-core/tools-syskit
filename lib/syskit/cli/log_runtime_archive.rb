# frozen_string_literal: true

require "archive/tar/minitar"
require "sys/filesystem"

module Syskit
    module CLI
        # Implementation of the `syskit log-runtime-archive` tool
        #
        # The tool archives Syskit log directories into tar archives in realtime,
        # compressing files using zstd
        #
        # It depends on the syskit instance using log rotation
        class LogRuntimeArchive
            DEFAULT_MAX_ARCHIVE_SIZE = 10_000_000_000 # 10G
            FREE_SPACE_LOW_LIMIT = 5_000_000_000 # 5 G
            FREE_SPACE_FREED_LIMIT = 25_000_000_000 # 25 G

            def initialize(
                root_dir, target_dir,
                logger: LogRuntimeArchive.null_logger,
                max_archive_size: DEFAULT_MAX_ARCHIVE_SIZE
            )
                if FREE_SPACE_LOW_LIMIT > FREE_SPACE_FREED_LIMIT
                    raise ArgumentError,
                          "cannot erase files: freed limit is smaller than " \
                          "low limit space."
                end

                @last_archive_index = {}
                @logger = logger
                @root_dir = root_dir
                @target_dir = target_dir
                @max_archive_size = max_archive_size
            end

            # Iterate over all datasets in a Roby log root folder and archive them
            #
            # The method assumes the last dataset is the current one (i.e. the running
            # one), and will only archive already rotated files.
            #
            # @param [Pathname] root_dir the log root folder
            # @param [Pathname] target_dir the folder in which to save the
            #   archived datasets
            def process_root_folder
                candidates = self.class.find_all_dataset_folders(@root_dir)
                running = candidates.last
                candidates.each do |child|
                    process_dataset(child, full: child != running)
                end
            end

            # Manages folder available space
            #
            # The method will check if there is enough space to save more log files
            # according to pre-established threshold.
            #
            # @param [integer] free_space_low_limit: required free space threshold, at
            #   which the archiver starts deleting the oldest log files
            # @param [integer] free_space_delete_until: post-deletion free space, at which
            #   the archiver stops deleting the oldest log files
            def ensure_free_space(free_space_low_limit = FREE_SPACE_LOW_LIMIT,
                free_space_delete_until = FREE_SPACE_FREED_LIMIT)
                stat = Sys::Filesystem.stat(@target_dir)
                available_space = stat.bytes_free

                return if available_space > free_space_low_limit

                until available_space >= free_space_delete_until
                    files = @target_dir.each_child.select(&:file?)
                    if files.empty?
                        Roby.warn "Cannot erase files: the folder is empty but the "\
                        "available space is smaller than the threshold."
                        break
                    end

                    removed_file = files.min
                    size_removed_file = removed_file.size
                    removed_file.unlink
                    available_space += size_removed_file
                end
            end

            def process_dataset(child, full:)
                use_existing = true
                loop do
                    open_archive_for(
                        child.basename.to_s, use_existing: use_existing
                    ) do |io|
                        if io.tell > @max_archive_size
                            use_existing = false
                            break
                        end

                        dataset_complete = self.class.archive_dataset(
                            io, child,
                            logger: @logger, full: full,
                            max_size: @max_archive_size
                        )
                        return if dataset_complete
                    end

                    use_existing = false
                end
            end

            # Create or open an archive
            #
            # The method will find an archive to open or create, do it and
            # yield the corresponding IO. The archives are named #{basename}.${INDEX}.tar
            #
            # @param [Boolean] use_existing if false, always create a new
            #   archive. If true, reuse the last archive that was created, if
            #   present, or create ${basename}.0.tar otherwise.
            def open_archive_for(basename, use_existing: true)
                last_index = find_last_archive_index(basename)

                index, mode =
                    if !last_index
                        [0, "w"]
                    elsif use_existing
                        [last_index, "r+"]
                    else
                        [last_index + 1, "w"]
                    end

                archive_path = @target_dir / "#{basename}.#{index}.tar"
                archive_path.open(mode) do |io|
                    io.seek(0, IO::SEEK_END)
                    yield(io)
                end
            end

            # Find the last archive index used for a given basename
            #
            # @param [String] basename the archive basename
            def find_last_archive_index(basename)
                i = @last_archive_index[basename] || 0
                last_i = nil
                loop do
                    candidate = @target_dir / "#{basename}.#{i}.tar"
                    return last_i unless candidate.exist?

                    @last_archive_index[basename] = last_i
                    last_i = i
                    i += 1
                end
            end

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
            def self.add_to_archive(archive_io, child_path, logger: null_logger)
                logger.info "adding #{child_path}"
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
                    add_to_archive_rollback(archive_io, start_pos, logger: logger)
                    false
                end
            rescue Exception => e # rubocop:disable Lint/RescueException
                Roby.display_exception(STDOUT, e)
                if start_pos
                    add_to_archive_rollback(archive_io, start_pos, logger: logger)
                end
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
            def self.add_to_archive_rollback(archive_io, start_pos, logger:)
                logger.warn "failed addition to archive, rolling back to known-good state"
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

            # Create a logger that will display nothing
            def self.null_logger
                logger = Logger.new(STDOUT)
                logger.level = Logger::FATAL + 1
                logger
            end

            # Archive the given dataset
            #
            # @param [IO] archive_io the IO of the target archive
            # @param [Pathname] path path to the dataset folder
            # @param [Boolean] full whether we're arching the complete dataset (true),
            #   or only the files that we know are not being written to (for log
            #   directories of running Syskit instances)
            # @return [Boolean] true if we're done processing this dataset. False
            #   if processing was interrupted by e.g. an archive that reached the
            #   max_archive_size limit
            def self.archive_dataset(
                archive_io, path,
                full:, logger: null_logger, max_size: DEFAULT_MAX_ARCHIVE_SIZE
            )
                logger.info(
                    "Archiving dataset #{path} in #{full ? 'full' : 'partial'} mode"
                )
                candidates = each_file_from_path(path).to_a
                complete, candidates =
                    if full
                        archive_filter_candidates_full(candidates)
                    else
                        archive_filter_candidates_partial(candidates)
                    end

                candidates.each_with_index do |child_path, i|
                    add_to_archive(archive_io, child_path, logger: logger)

                    if archive_io.tell > max_size
                        return (complete && (i == candidates.size - 1))
                    end
                end

                complete
            end

            # Enumerate the children of a path that are files
            #
            # @yieldparam [Pathname] file_path the full path to the file
            def self.each_file_from_path(path)
                return enum_for(:each_file_from_path, path) unless block_given?

                path.each_entry do |child_path|
                    full = path / child_path
                    yield(full) if full.file?
                end
            end

            # Filters all candidates for archiving to return the ones that should
            # be archived in `full` mode at this point in time
            #
            # The method either returns the remaining rotated logs, or if there
            # are none, the non-rotated files. This ensures that the archiver groups
            # all non-rotated files in a single archive.
            #
            # @param [Array<Pathname>] candidates
            # @return [(Boolean,Array<Pathname>)] a flag that tell whether the candidate
            #   array is complete or not, and the files that should be archived. If
            #   the flag is true, the assumption is that after having archived the files
            #   that were returned, the archiving loop should try archiving again.
            def self.archive_filter_candidates_full(candidates)
                per_file_and_idx = filter_and_group_pocolog_files(candidates)
                rotated_logs = per_file_and_idx.each_value.flat_map(&:values)
                unless rotated_logs.empty?
                    return [(candidates - rotated_logs).empty?, rotated_logs]
                end

                [true, candidates]
            end

            # Filters all candidates for archiving to return the ones that should
            # be archived in `partial` mode at this point in time
            #
            # The method returns the rotated logs that are known to be complete.
            #
            # @param [Array<Pathname>] candidates
            # @return [(true,Array<Pathname>)] files that should be archived. The
            #   boolean is here for consistency with {.archive_filter_candidates_full}
            def self.archive_filter_candidates_partial(candidates)
                per_file_and_idx =
                    filter_and_group_pocolog_files(candidates)
                    .each_value { |logs| logs.delete(logs.keys.max) }

                complete_log_files = per_file_and_idx.flat_map do |_, logs|
                    logs.keys.sort.map { |i| logs[i] }
                end

                [true, complete_log_files]
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
