require 'acts_as_materialized_tree/active_record'
ActiveRecord::Base.send :include, ActiveRecord::Acts::MaterializedTree
