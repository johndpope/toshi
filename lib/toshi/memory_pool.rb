require 'set'

module Toshi
  # This class functions similar to bitcoind's CTxMemPool and uses Sequel/PostgreSQL for storage.
  class MemoryPool
    include Logging

    def initialize(output_cache)
      @output_cache = output_cache
    end

    # Does this tx exist in our view of the memory pool?
    def exists?(binary_tx_hash)
      hex_hash = Toshi::Utils.bin_to_hex_hash(binary_tx_hash)
      tx = Toshi::Models::UnconfirmedTransaction.from_hsh(hex_hash)
      return false if tx && !tx.in_memory_pool?
      tx != nil
    end

    # Are we currently aware of this tx on the main branch or memory pool?
    def exists_including_main_branch?(binary_tx_hash)
      return true if exists?(binary_tx_hash)
      hex_hash = Toshi::Utils.bin_to_hex_hash(binary_tx_hash)
      tx = Toshi::Models::Transaction.from_hsh(hex_hash)
      return tx != nil && tx.in_view?
    end

    # Does the unspent output exist in the memory pool?
    def is_output_available?(tx_hash, position)
      output = Toshi::Models::UnconfirmedOutput.where(hsh: tx_hash, position: position).first
      return false if !output || !output.transaction.in_memory_pool?
      !output.spent
    end

    # Are any of the outputs spent by another tx in our view of the memory pool?
    def any_inputs_spent?(tx)
      tx.inputs.each{|txin|
        hash, i = txin.previous_output, txin.prev_out_index
        if input = Toshi::Models::UnconfirmedInput.where(prev_out: hash, index: i).first
          return true if !input.transaction.is_orphan?
        end
      }
      false
    end

    # Add the tx to the memory pool w/o validation (done by the processor)
    def add_unchecked(tx, on_disconnect=false)
      if on_disconnect
        # we may be disconnecting a blockchain tx so handle that like so
        Toshi::Models::Transaction.where(hsh: tx.hash)
          .update(pool: Toshi::Models::Transaction::BLOCK_POOL)
      end

      t = Toshi::Models::UnconfirmedTransaction.from_hsh(tx.hash)
      if t
        raise "BUG: should only be true for orphan transactions" if !t.is_orphan?
        t.update(pool: Toshi::Models::UnconfirmedTransaction::MEMORY_POOL)
      else
        t = Toshi::Models::UnconfirmedTransaction.create_from_tx(tx)
      end
      t.mark_spent_outputs
      t.update_unconfirmed_ledger_for_inputs(tx, @output_cache)
      t
    end

    # Track orphan txs in the hope that their parent(s) show up
    # Isn't really part of CTxMemPool but this seems like the logical place for this method.
    # See AddOrphanTx in bitcoind.
    def add_orphan_tx(tx)
      return false if Toshi::Models::UnconfirmedTransaction.from_hsh(tx.hash)

      # TODO: bitcoind limits the # of orhpans it will track.
      # we should consider doing the same except that bitcoind
      # performs random eviction and LRU logic makes more sense.
      # may be worth submitting a patch to bitcoind as well.

      # "Ignore big transactions, to avoid a
      # send-big-orphans memory exhaustion attack. If a peer has a legitimate
      # large transaction with a missing parent then we assume
      # it will rebroadcast it later, after the parent transaction(s)
      # have been mined or received.
      # 10,000 orphans, each of which is at most 5,000 bytes big is
      # at most 500 megabytes of orphans:" - bitcoind
      if (tx.payload || tx.to_payload).bytesize > 5000
        return false
      end

      # create the tx in the orphan pool
      Toshi::Models::UnconfirmedTransaction
        .create_from_tx(tx, Toshi::Models::UnconfirmedTransaction::ORPHAN_POOL)

      true
    end

    # Get a set of orphan txs given the hash of a potential input tx
    def get_orphan_txs_by_prev_hash(tx_hash)
      orphan_txs = []
      Toshi::Models::UnconfirmedInput.where(prev_out: tx_hash).each{|input|
        transaction = input.transaction
        if transaction.is_orphan?
          orphan_txs << transaction.bitcoin_tx
        end
      }
      orphan_txs
    end

    # Remove a tx from the memory pool
    # CTxMemPool::remove has a 'fRecursive' flag but whenever we use this it is always true.
    # we're really only using this to move mempool txs to the conflicted pool as we move things to
    # the tip pool via remove_for_block.
    #
    def remove(tx)
      # recursively find conflicts -- except don't actually use recursion.
      # some conflicted unconfirmed spend chains can get fairly long.
      conflicts = [ tx ]
      seen = Set.new
      i = 0
      while i < conflicts.length do
        tx = conflicts[i]
        unless seen.include?(tx.hash)
          tx.outputs.each_with_index{|txout,i|
            Toshi::Models::UnconfirmedInput.where(prev_out: tx.hash, index: i).each{|input|
              conflicts << input.transaction.bitcoin_tx
            }
          }
          seen << tx.hash
        end
        i += 1
      end

      tx_hashes = conflicts.map{|tx| tx.hash}

      # mark the transactions conflicted
      Toshi::Models::UnconfirmedTransaction.where(hsh: tx_hashes)
        .update(pool: Toshi::Models::UnconfirmedTransaction::CONFLICT_POOL)

      # this might be a disconnected blockchain transaction
      Toshi::Models::Transaction.where(hsh: tx_hashes)
        .update(pool: Toshi::Models::Transaction::CONFLICT_POOL)
    end

    # Helper method.
    def remove_conflicts_step(query, in_block_set)
      Toshi::Models::UnconfirmedInput.where(query).each{|input|
        next if in_block_set.include?(input.hsh)
        # remove it and any dependents
        logger.warn{ "removing conflicted tx: #{input.hsh}" }
        self.remove(input.transaction.bitcoin_tx)
      }
    end

    # Remove transactions which depend on inputs of txs in the block.
    def remove_conflicts(block, in_block_set)
      query = ''
      block.tx.each{|tx|
        tx.inputs.each{|txin|
          next if txin.coinbase?
          if !query.empty?
            if query.bytesize > (1024*512)
              # Do these in reasonably sized steps.
              self.remove_conflicts_step(query, in_block_set)
              query = ''
            else
              query << ' OR '
            end
          end
          # Find other spenders of the same previous outputs.
          # TODO: Figure out how to use Sequel or named parameters.
          query << '(prev_out = \''
          query << txin.previous_output
          query << '\' AND index = '
          query << txin.prev_out_index.to_s
          query << ')'
        }
      }
      self.remove_conflicts_step(query, in_block_set) unless query.empty?
    end

    # Remove all txs in the block from the memory pool.
    def remove_for_block(block)
      in_block_set = Set.new
      block.tx.each{|tx| in_block_set.add?(tx.hash) }

      # remove any now conflicted txs from the memory pool --
      # these are txs which spend outputs spent by txs in this new block. why would this happen?
      # maybe a tx in the block wasn't relayed to us but an associated double-spend was.
      self.remove_conflicts(block, in_block_set)

      tx_hashes = in_block_set.to_a

      # make sure the transactions are on the tip pool (if they previously existed.)
      Toshi::Models::Transaction.where(hsh: tx_hashes)
        .update(pool: Toshi::Models::Transaction::TIP_POOL)

      # TODO: should probably transfer timestamps and other information
      Toshi::Models::UnconfirmedTransaction.remove_for_block(tx_hashes)
      Toshi::Models::UnconfirmedRawTransaction.where(hsh: tx_hashes).delete
    end

    # Create a TxOut given a TxIn.
    def output_for_outpoint(txin)
      unconfirmed_output = Toshi::Models::UnconfirmedOutput.prevout(txin)
      Bitcoin::Protocol::TxOut.new(unconfirmed_output.amount, unconfirmed_output.script) rescue nil
    end

    # Lock access to the memory pool for the remainder of the wrapping db transaction.
    def lock
      # Automatically released when the wrapping db transaction completes.
      # The owning session/transaction can also safely call this many times w/o deadlocking.
      Toshi.db.run("select pg_advisory_xact_lock(#{Toshi::Lock::MEMPOOL})")
    end
  end
end
