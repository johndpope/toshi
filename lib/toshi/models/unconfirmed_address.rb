module Toshi
  module Models
    class UnconfirmedAddress < Sequel::Model

      many_to_many :unconfirmed_outputs,
                   :left_key => :address_id,
                   :right_key => :output_id,
                   :join_table => :unconfirmed_addresses_outputs

      def total_received
        @received ||= outputs.sum(:amount).to_i
      end

      def total_sent(address=nil)
        return @sent if @sent
        @sent = spent_outputs.sum(:amount).to_i
        if address
          @sent += amount_confirmed_spent_by_unconfirmed(address)
        end
        @sent
      end

      # unconfirmed balance
      def balance(address_model=nil)
        address_model ||= Address.where(address: address).first
        total_received - total_sent(address_model)
      end

      def amount_confirmed_spent_by_unconfirmed(address)
        query = "select sum(outputs.amount) as total
                        from outputs,
                             addresses_outputs,
                             unconfirmed_inputs
                        where unconfirmed_inputs.prev_out = outputs.hsh and
                              unconfirmed_inputs.index = outputs.position and
                              addresses_outputs.address_id = #{address.id} and
                              addresses_outputs.output_id = outputs.id and
                              outputs.branch = #{Block::MAIN_BRANCH}"
        query = Toshi.db.fetch(query).first
        query[:total].to_i
      end

      def outputs
        unconfirmed_outputs_dataset
      end

      def unspent_outputs
        unconfirmed_outputs_dataset.where(spent: false)
      end

      def spent_outputs
        unconfirmed_outputs_dataset.where(spent: true)
      end

      HASH160_TYPE = 0
      P2SH_TYPE    = 1

      def type
        case address_type
        when HASH160_TYPE; :hash160
        when P2SH_TYPE;    :p2sh
        end
      end

      def transactions(offset=0, limit=100)
        tids = Toshi.db[:unconfirmed_ledger_entries].where(address_id: id)
          .join(:unconfirmed_transactions, :id => :transaction_id).where(pool: UnconfirmedTransaction::MEMORY_POOL)
          .select(:transaction_id).group_by(:transaction_id).order(Sequel.desc(:transaction_id))
          .offset(offset).limit(limit).map(:transaction_id)
        return [] unless tids.any?
        UnconfirmedTransaction.where(id: tids).order(Sequel.desc(:id))
      end

      def to_hash(options={})
        self.class.to_hash_collection([self], options).first
      end

      def self.to_hash_collection(addresses, options={})
        Toshi::Utils.sanitize_options(options)

        collection = []

        addresses.each{|address|
          hash = {}
          hash[:hash] = address.address
          hash[:balance] = 0
          hash[:received] = 0
          hash[:sent] = 0

          hash[:unconfirmed_received] = address.total_received
          hash[:unconfirmed_sent] = address.total_sent
          hash[:unconfirmed_balance] = address.balance

          if options[:show_txs]
            hash[:unconfirmed_transactions] = UnconfirmedTransaction.to_hash_collection(address.transactions)
            hash[:transactions] = []
          end

          collection << hash
        }

        return collection
      end

      def to_json(options={})
        to_hash(options).to_json
      end
    end
  end
end
