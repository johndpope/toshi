require 'pg'
require 'sequel'

module Toshi
  class << self
    attr_accessor :db

    def connect_database
      self.db = Sequel.connect(settings[:database_url])
    end
  end
end
