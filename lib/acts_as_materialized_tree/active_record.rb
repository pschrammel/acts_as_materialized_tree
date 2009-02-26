# Copyright (C) Brian Candler 2008. Released under the MIT licence.

module ActiveRecord
  module Acts #:nodoc:
    module MaterializedTree #:nodoc:
      def self.included(base)
        base.extend(ClassMethods)
      end

=begin rdoc
acts_as_materialized_tree builds a 'materialized tree' data structure - that
is, one where each node contains an explicit path. This allows you to:

* Find all ancestors or descendants with a single DB query [expensive
  in acts_as_tree]
* Limit searches to arbitrary subtrees [expensive in acts_as_tree]
* Add and remove children easily [expensive in acts_as_nested_set]
* Output nodes in natural order (parent immediately before all its children)
  with a simple sort, which is done automatically by default.

The limitations are:

* If you graft a whole subtree to some other part of the tree, the
  subtree needs to be relabeled [cheap in acts_as_tree]
* It's expensive to count descendants [cheap in acts_as_nested_set]
* Children can only be added at the end of the existing children,
  not inserted before

=== The data structure

Each node contains a path attribute, by default called 'path'. This is a
string which gives the full path to the node from the root.

This is similar to the Unix filesystem idea of path: / is the root node,
/foo is a node under the root, /foo/bar is a node under that node, and so
on.

                     root (/)
                       |
                 +-----------+
               /foo         /other
                 |
            +---------+
        /foo/bar    /foo/baz

In acts_as_materialized_tree, each path component is a number, and these
numbers are encoded in a compressed string form. The root node's path is
the empty string. So the above example would have paths of

                       ""
                       |
                 +-----+-----+
                "0"         "1"
                 |
            +----+----+
           "00"      "01"

The encoding is as follows, given that 'x' is a character 0-9 or A-V,
representing numbers 0 to 31 respectively.

        x          =  0...32
        Wxx        =  32...2^10
        Xxxxx      =  2^10...2^20
        Yxxxxxx    =  2^20...2^30
        Zxxxxxxxx  =  2^30...2^40

Hence the maximum number of children for any single node is 2^40.

Each node also contains an integer column, by default called "next_child",
which gives the sequence number of the next child to be allocated.

See ActiveRecord::Acts::MaterializedTree::InstanceMethods for a list of the
associations provided. Where these are a collection, e.g. descendants, then
you actually get an anonymous scope, which allows you to perform group
operations in SQL without retrieving the records. e.g.

    foo.descendants.count

or to add further constraints, e.g.

    foo.descendants.find(:all, :conditions => {:type => 'Wibble'})

=== Implementation notes

It is possible to implement some of these queries in several different ways.
For example, to get self_and_descendants of node ABC, you can do:

   path LIKE 'ABC%'
   path >= 'ABC' AND path < 'ABD'
   path BETWEEN 'ABC' AND 'ABCZZ'

Similarly for descendants you can do

   path LIKE 'ABC%' AND path != 'ABC'
   path > 'ABC' AND path < 'ABD'
   path BETWEEN 'ABC0' AND 'ABCZZ'

It's not clear to me which (if any) is going to produce faster results for
any particular database engine.

Ancestors are found by direct decomposition of the path:

  path IN ('AB', 'A', '')

To list only first-generation children is ugly, and requires the LIKE
operator:

  path LIKE 'ABC_' OR
  path LIKE 'ABCW__' OR
  path LIKE 'ABCX____' OR
  path LIKE 'ABCY______' OR
  path LIKE 'ABCZ________'

This is a limitation of this way of packing the path string. However this
variable-length encoding does allow for trees which have both broad and
deep portions (i.e. some nodes with lots of children, and some nodes with
many levels of descendants).

=== Tree structure integrity

Whilst a database constraint can enforce that two nodes do not have the
same path, with this path scheme it cannot enforce tree structure (i.e.
that the parent node exists). Hence it is possible to get into a state
where a child has no children, but it does have grandchildren. If you were
to browse the nodes by following their children only then these would be
unreachable.

=== SQL compatibility notes

In add_child, I need to concatenate two strings as part of an UPDATE
operation. In sqlite there is no concat() function, but in mysql there is
no || operator. So I try concat() first, and fall back to || if that fails.

The LIKE operator is case-sensitive in some databases, but case-insensitive
in others. This shouldn't matter though, since the path strings use only
upper-case characters. (This was one reason for using base32 not base64)

=== Performance

The path field needs to be indexed, preferably with a unique index. Given
this, the database query optimiser should be able to make a reasonable stab
at the best way to optimise a particular query. For example,

   node.self_and_descendants.find(:conditions=>["name like ?","brian%"])
   
will expand to something like

   (path BETWEEN 'ABC' AND 'ABCZZ') AND (name LIKE 'brian%')

A good database should be able to estimate (using indexes) which of the two
parts of the query will give the smaller result set, so as to be able to
organise the join appropriately. These estimates may not always be accurate,
and actual performance will depend on your database implementation.

(TODO: collect some real figures for million-row datasets)

=== See also

* acts_as_tree
* acts_as_nested_set
* BetterNestedSet
=end

      module ClassMethods
        # Configuration options are:
        #
        # * +path_column+ - specifies the column name to use for keeping the path string (default: +path+)
        # * +seq_column+ - column name for integer sequence number of the next child (default: +next_child+)
        # * +order+ - ordering string. Defaults to path_column. Set to nil to prevent ordering.
        # * +scope+ - a symbol (column name), hash (conditions) or string (conditions) to restrict records within the tree.
        # * +scope_options+ - a lower-level way to specify scope options for finer control
        #
        # :scope and/or :scope_options are only needed if there are to be
        # multiple trees (and hence multiple roots) within the same table.
        #
        # If :scope is a symbol, then _id will be added to it automatically
        # if required, and then this column will be used to identify records
        # within the same tree.
        #
        # If :scope_options is a Hash, then any :scope and :order will be
        # merged into it.
        #
        # If :scope_options is a lambda, then it needs to take one argument
        # which is an existing object; it should return the conditions for
        # the tree of which this object is a member. In this case, the :scope
        # and :order options are ignored. Example:
        #
        #    acts_as_materialized_tree :scope_options => lambda { |obj|
        #      { :conditions => { :tree_id => obj.tree_id }, :order => :path }
        #    }
        def acts_as_materialized_tree(options = {})
          klass = self
          include ActiveRecord::Acts::MaterializedTree::InstanceMethods

          path_column   = (options[:path_column] || :path).freeze
          seq_column    = (options[:seq_column]  || :next_child).freeze
          scope_options = options[:scope_options] || {}
          scope         = options[:scope]
          order         = options.has_key?(:order) ? options[:order] : path_column

          define_method(:path_column) { path_column }
          define_method(:seq_column) { seq_column }
          
          #Fails unless a logger is present:
          #attr_protected path_column
          #attr_protected seq_column

          if scope_options.is_a?(Proc)
            define_method(:tree_scope) { klass.scoped(scope_options[self]) }
            # in this case we ignore :order and :scope
          elsif scope.is_a?(Symbol)
            scope = "#{scope}_id".intern unless scope.to_s =~ /_id$/
            scope_options[:order] = order if order
            define_method(:tree_scope) {
              klass.scoped(scope_options.merge(:conditions => {scope => send(scope)}))
            }
          else
            scope_options[:conditions] = scope if scope
            scope_options[:order] = order if order
            define_method(:tree_scope) {
              klass.scoped(scope_options)
            }
          end

          scope_options.freeze

          before_destroy do |obj|
            obj.descendants.delete_all
          end
        end
      end

      # NOTE: when you call 'destroy' on an object, all its descendants will
      # be deleted with a single SQL statement (delete_all), without calling
      # any before_destroy callbacks except for the top-level node.
      module InstanceMethods
        PATH_SCAN = /[0-9A-V]|W[0-9A-V]{2}|X[0-9A-V]{4}|Y[0-9A-V]{6}|Z[0-9A-V]{8}/

        # A scope representing the entire tree of which this node is a member
        def tree_scope
          raise ActiveRecordError, "tree_scope must be defined dynamically"
        end
        
        # The path column split into individual items, e.g.
        #     "0CW124"  =>  ["0", "C", "W12", "4"]
        def path_components
          self[path_column].scan(PATH_SCAN)
        end

        # Collection of all root nodes
        def roots
          self.class.base_class.scoped(:conditions => {path_column=>''})
        end

        # Returns +true+ is this is a root node.
        def root?
          path_components.empty?
        end

        # Number indicating the level (0 = root)
        def level
          path_components.size
        end
        
        # Returns +true+ if this entry has a valid path.
        def path_valid?
          path_components.join == self[path_column]
        end
        
        # Return the path of the parent
        def parent_path
          components = path_components
          components.pop
          components.join
        end
        
        # Load the parent object
        def parent(force = false)
          return @_parent if !force && defined?(@_parent)
          @_parent = tree_scope.find(:first,
            :conditions => {path_column => parent_path})
        end

        # Load the root object
        def root(force = false)
          return @_root if !force && defined?(@_root)
          @_root = tree_scope.find(:first,
            :conditions => {path_column=>''})
        end

        # Return an array of paths of the ancestors, from root downwards.
        # Includes self only if include_self argument is true.
        def ancestor_paths(include_self = false)
          components = self[path_column].scan(PATH_SCAN)
          components.pop unless include_self
          paths = []
          while !components.empty?
            paths.unshift components.join
            components.pop
          end
          paths.unshift("") if (include_self || !root?)
          paths
        end

        # Collection of ancestor objects
        def ancestors
          ap = ancestor_paths
          return [] if ap.empty?
          tree_scope.scoped(:conditions => {path_column => ap})
        end
        
        # Collection of ancestor objects including self
        def self_and_ancestors
          ap = ancestor_paths(true)
          tree_scope.scoped(:conditions => {path_column => ap})
        end

        # Collection of all descendants of this node
        def descendants
          tree_scope.scoped(:conditions =>
            {path_column => (send(path_column)+'0'..send(path_column)+'ZZ')})
        end
        alias :all_children :descendants
        
        # Collection of this node and all its descendants
        def self_and_descendants
          tree_scope.scoped(:conditions =>
            {path_column => (send(path_column)..send(path_column)+'ZZ')})
        end
        alias :full_set :self_and_descendants
        
        # Collection of immediate children of this node (or the given node)
        def children(parent_path = self[path_column])
          tree_scope.scoped(:conditions => [
            "#{path_column} LIKE ?" \
            " OR #{path_column} LIKE ?" \
            " OR #{path_column} LIKE ?" \
            " OR #{path_column} LIKE ?" \
            " OR #{path_column} LIKE ?",
            parent_path + '_',
            parent_path + 'W__',
            parent_path + 'X____',
            parent_path + 'Y______',
            parent_path + 'Z________'])
        end
        alias :direct_children :children

        # Collection of this node and its siblings
        def self_and_siblings
          return [self] if root?
          children(parent_path)
        end
        
        # Collection of siblings excluding this node
        def siblings
          return [] if root?
          children(parent_path).scoped(:conditions =>
            ["#{path_column} != ?", self[path_column]])
        end
        
        # Add a new child to this node. The current node must already have
        # been saved to the database.
        #
        # If the child is a new record, it is saved. The return value is
        # the result of the save, so you can test:
        #
        #    if foo.add_child(bar)
        #      ... save was successful
        #    end
        #
        # If the child already exists in the database, the child and its
        # descendants will be renumbered so as to live under this node (i.e.
        # this is a tree graft operation). The result is the value of the
        # update_all operation, which should return the number of rows
        # updated. The child object will need to be reloaded if you wish
        # to access its new path attribute.
        #
        # In both cases, if there is a simple scoping rule then the child
        # or children will have their scope column(s) updated to match
        # this node. This means it is possible to graft a subtree from
        # one tree to another. This should work if the scoping conditions
        # generate a hash:
        #     :conditions => {:foo => 123}
        # but not if they are a string or interpolated string:
        #     :conditions => "foo = 123"
        #     :conditions => ["foo=?",123]
        def add_child(child)
          if new_record?
            raise ActiveRecordError, "add_child not supported unless this node already in database"
          end

          seq = allocate_next_seq
          comp = encode_path_component(seq)
          npath = send(path_column) + comp

          if child.new_record?
            child.write_attribute(path_column, npath)
            child.write_attribute(seq_column, 0) if child.send(seq_column).nil?
            # Now try to copy the scope condition columns from the parent
            cond = tree_scope.proxy_options[:conditions]
            if cond.is_a? Hash
              cond.each do |k,v|
                child.write_attribute(k, v)
              end
            end
            child.instance_variable_set('@_parent',self)
            return child.save
          else
            # Should we do this in a transaction? But perhaps the caller
            # already has one open

            upd2 = [""]
            cond = tree_scope.proxy_options[:conditions]
            if cond.is_a? Hash
              cond.each do |k,v|
                upd2.first << ", #{k}=?"
                upd2 << v
              end
            end

            begin
              upd1 = ["#{path_column} = concat(?, substr(#{path_column},?,9999))", npath, child.send(path_column).length+1]
              child.self_and_descendants.update_all([upd1[0]+upd2[0]] + upd1[1..-1] + upd2[1..-1])
            rescue ActiveRecord::StatementInvalid
              # If concat() is invalid, try ||
              upd1 = ["#{path_column} = ? || substr(#{path_column},?,9999)", npath, child.send(path_column).length+1]
              child.self_and_descendants.update_all([upd1[0]+upd2[0]] + upd1[1..-1] + upd2[1..-1])
            end
          end
        end

      private
      
        # Allocate the next sequence number atomically
        def allocate_next_seq
          retries = 20
          while true
            reload
            seq = send(seq_column)
            case r = self.class.base_class.update_all(
              ["#{seq_column}=?",seq+1],
              ["#{self.class.base_class.primary_key}=? and #{seq_column}=?",id,seq])
            when 0
              retries -= 1
              raise ActiveRecordError, "Unable to allocate from #{seq_column}" if retries <= 0
              sleep rand(0.5)
            when 1
              return seq
            else
              raise ActiveRecordError, "Unexpected update result #{r.inspect} in allocate_next_seq"
            end
          end
        end

        # Encode a number as a path component:
        #   0..31         A-V
        #   32..2^10-1    Wxx
        #   2^10..2^20-1  Xxxxx
        #   2^20..2^30-1  Yxxxxxx
        #   2^30..2^40-1  Zxxxxxxxx
        def encode_path_component(seq)
          if seq < 0
            raise ActiveRecordError, "Negative path components are not permitted"
          elsif seq < (1<<5)
            seq.to_s(32)
          elsif seq < (1<<10)
            sprintf("W%2s", seq.to_s(32))
          elsif seq < (1<<20)
            sprintf("X%4s", seq.to_s(32))
          elsif seq < (1<<30)
            sprintf("Y%6s", seq.to_s(32))
          elsif seq < (1<<40)
            sprintf("Z%8s", seq.to_s(32))
          else
            raise ActiveRecordError, "Next value in #{seq_column} too large"
          end.gsub(' ','0').upcase
        end
      end
    end
  end
end

#--
#TODO:
#
#Check compatibility across mysql, postgres etc. Does the update_all
#operation always return the row processed count? We rely on this in
#allocate_next_seq.
#
#Prevent tree structure violations, e.g. avoid grafting a node onto one of
#its children.
#
#Fix attr_protected. Make the path and next_child columns entirely read-only?
#
#Add an optional counter cache for number of children
#
#Generate XML output; this should be easy given that a simple
#descendants query gives parent followed by children. (Would prefer
#not to build up an entire Array first though)
#
#Perhaps children should be a proper AssociationCollection?
#This would allow you to build subtrees of objects in RAM, and then write
#them to disk by adding the top node to an existing in-database node.
#However, it would be very hard for updates to the 'children' to be
#reflected in 'descendants', and vice versa; the 'parent' and 'ancestors'
#relations could be awkward; and having a mixture of on-disk and in-RAM
#records could be tricky to handle.
#('descendants' could remain as an anonymous scope of on-disk records only)
#++
