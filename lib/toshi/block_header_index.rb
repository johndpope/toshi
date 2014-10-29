require 'set'

module Toshi

  # Implements a structure similar to bitcoind's mapBlockIndex
  # Valid block headers are stored in memory (main/side chain) and
  # allow to efficiently navigate back in the chain.
  # Index provides lazy fill (so we don't need to read the whole DB on startup).
  # It finds block headers in the storage if they are missing and adds them automatically.
  # Has optional limit to keep at most N blocks in memory.

  class BlockHeaderIndex

    # Reference to BlockchainStorage instance so we can retrieve block headers automatically.
    # Can be nil, in which case blocks are not loaded/inserted automatically.
    attr_accessor :storage

    def initialize
      @storage = nil
      @headers_by_hash = {}
      @headers_count = 0
      @headers_limit = 2016

      # Strange name but its bitcoind analog is setBlockIndexValid.
      # From the reference implementation:
      #
      # "The set of all CBlockIndex entries with BLOCK_VALID_TRANSACTIONS or better that are at least
      #  as good as our current tip. Entries may be failed, though."
      #
      # In our case it will never contain failures. Just main and side chain blocks. It will keep
      # blocks with lesser work but they eventually get pruned. It's cleaner than the active pruning
      # bitcoind performs. We aren't that hard-pressed for memory.
      @set_block_index_valid = SortedSet.new
    end

    # returns a block header for hash or nil if it's not found.
    # attempts to load a block from storage if it exists
    def block_header_for_hash(hash)
      # return existing header or try to load one from storage if we have one.
      @headers_by_hash[hash] ||= begin
        if @storage
          block, created_at = @storage.valid_block_for_hash_with_created_at(hash)
          if block
            block_header = block_header_from_block(block, created_at)

            # If we have a previous block, use its height and total_work.
            # Otherwise, load them from the DB.
            if prev_block_header = @headers_by_hash[block_header.sha2_hash]
              block_header.height = (prev_block_header.height + 1) if prev_block_header.height
              block_header.total_work = prev_block_header.total_work + block.block_work
            else
              block_header.height = @storage.height_for_block(block.hash)
              block_header.total_work = @storage.total_work_up_to_block_hash(block.hash)
            end

            @headers_count += 1
            prune_blocks
            block_header
          else
            nil
          end
        end
      end
    end

    # Quick check if the block header is in index
    def block_header_in_index?(hash)
      !!@headers_by_hash[hash]
    end

    # Inserts a block header based on block (if it's not there yet).
    # If previous block is not included in index, raises an exception.
    # Argument is an instance of Bitcoin::Protocol::Block
    def insert_block(block, height, prev_work, created_at)
      if @headers_by_hash[block.hash]
        return
      end
      block_header = block_header_from_block(block, created_at)
      block_header.height = height if height
      block_header.total_work = prev_work + block.block_work
      @headers_by_hash[block.hash] = block_header
      @headers_count += 1
      @set_block_index_valid.add?(block_header)
      prune_blocks
    end

    def remove_block(block)
      block_header = @headers_by_hash[block.hash]
      @set_block_index_valid.delete?(block_header) if block_header
      @headers_count -= 1 if @headers_by_hash.delete(block.hash)
    end

    # Removes excessive blocks according to @headers_limit.
    # It does so in least-work order.
    def prune_blocks
      # Do nothing if limit is not set.
      return if (@headers_limit || 0) < 1

      while @headers_count > @headers_limit
        # Index 0 should be the least-recently used key.
        if obj_hash = @headers_by_hash.keys[0]
          obj = @headers_by_hash[obj_hash]
          if obj
            @set_block_index_valid.delete?(obj)

            # Break references from its children:
            (obj.next_block_headers || []).each do |child|
              child.previous_block_header = nil
            end

            # Cleanup
            obj.next_block_headers = nil

            # Update counter
            @headers_count -= 1
          end

          # Remove item from the index
          @headers_by_hash.delete(obj_hash)
        end
      end
    end

    # Inspired by FindMostWorkChain().
    def find_most_work_chain
      block_header = @set_block_index_valid.first
      return nil unless block_header
      block_header.sha2_hash
    end

    private

    def block_header_from_block(block, created_at)
      block_header = BlockHeader.new
      block_header.block_header_index = self # reference to its parent
      block_header.sha2_hash       = block.hash
      block_header.ver             = block.ver
      block_header.prev_block      = block.prev_block
      block_header.prev_block_hex  = block.prev_block_hex
      block_header.mrkl_root       = block.mrkl_root
      block_header.time            = block.time
      block_header.bits            = block.bits
      block_header.nonce           = block.nonce
      block_header.created_at      = created_at
      block_header
    end

    # Concrete item for the index.
    class BlockHeader
      # Reference to an index that owns this block_header
      attr_accessor :block_header_index

      # Hash of this block
      attr_accessor :sha2_hash

      # Reference to the previous block header
      attr_accessor :previous_block_header

      # List of next block headers (private ivar, it is updated only when the child links to this block)
      attr_accessor :next_block_headers

      # block version
      attr_accessor :ver

      # previous block hash (binary)
      attr_accessor :prev_block

      # previous block hash (lowercase hex string)
      attr_accessor :prev_block_hex

      # merkle root of transactions (binary)
      attr_accessor :mrkl_root

      # block generation time - 32-bit unix timestamp
      attr_accessor :time

      # difficulty in "compact" integer encoding
      attr_accessor :bits

      # nonce (number counted when searching for block hash matching target)
      attr_accessor :nonce

      # Extensions:
      attr_accessor :height
      attr_accessor :total_work # cumulative work
      attr_accessor :created_at

      # compare headers by hash
      def ==(other)
        self.sha2_hash == other.sha2_hash
      end

      def eql?(other)
        self == other
      end

      # See: CBlockIndexWorkComparator
      # Note that the logic is inverted since we want to iterate in most-work order
      # and don't have reverse iterators like STL's set.
      def <=>(other)
        # compare total work
        return 1 if self.total_work < other.total_work
        return -1 if self.total_work > other.total_work

        # in the event of a tie, who was first?
        return 1 if self.created_at > other.created_at
        return -1 if self.created_at < other.created_at

        # same block
        return 0
      end

      # Similar to the above but this can also handle new blocks.
      # Logic is also not inverted.
      def is_more_work?(other, new_hash, new_work)
        total_new_work = self.total_work + new_work
        return true if total_new_work > other.total_work
        return false if total_new_work < other.total_work

        block_header = @block_header_index.block_header_for_hash(new_hash)
        # If the "new" block doesn't exist yet it's newer and therefore the loser.
        return false unless block_header

        return true if block_header.created_at < other.created_at
        return false if block_header.created_at > other.created_at
        false
      end

      def previous_block_header
        # Return linked block header or try to load it dynamically from the index.
        @previous_block_header ||= begin
          if self.prev_block # skip genesis block
            prev = @block_header_index.block_header_for_hash(self.prev_block_hex)

            # Should let ancestor know about the child block that references it, so
            # ancestor can break this reference when being pruned from the index.
            if prev
              prev.next_block_headers ||= []
              if !prev.next_block_headers.include?(self)
                prev.next_block_headers << self
              end
            end
            prev
          end
        end
      end

    end
  end
end
