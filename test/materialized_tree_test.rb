#!/usr/bin/env ruby -w
require 'test/unit'

require 'rubygems'
require 'active_record'

$:.unshift File.dirname(__FILE__) + '/../lib'
require File.dirname(__FILE__) + '/../init'

ActiveRecord::Base.establish_connection(:adapter => "sqlite3", :dbfile => ":memory:")
#ActiveRecord::Base.logger = Logger.new(STDERR)
#ActiveRecord::Base.colorize_logging = false

# AR keeps printing annoying schema statements
$stdout = StringIO.new

#### Initial test using defaults for all column names ####

class MatreeDefault < ActiveRecord::Base
  acts_as_materialized_tree
end

class MatreeDefaultTest < Test::Unit::TestCase
  def setup
    ActiveRecord::Schema.define(:version => 1) do
      create_table :matree_defaults do |t|
        t.string  :path, :null=>false, :default=>""
        t.integer :next_child, :null=>false, :default=>0
      end
      add_index :matree_defaults, :path, :unique=>true
    end
  end
  
  def teardown
    ActiveRecord::Base.connection.tables.each do |table|
      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  def test_build_tree
    root = MatreeDefault.new
    root.save!
    root.add_child(n1 = MatreeDefault.new)
    root.add_child(MatreeDefault.new)
    n1.add_child(MatreeDefault.new)
    root.add_child(MatreeDefault.new)
    n1.add_child(MatreeDefault.new)

    res = root.self_and_descendants.map { |e| [e.path, e.next_child] }
    assert_equal [
      ["", 3],
      ["0", 2],
      ["00", 0],
      ["01", 0],
      ["1", 0],
      ["2", 0],
    ], res
  end
end

#### A more exhaustive test ####
#### We override :path_column and :seq_column to ensure that 'path' or
#### 'next_child' aren't hardcoded anywhere

class MatreeUnscoped < ActiveRecord::Base
  acts_as_materialized_tree :path_column => :mypath, :seq_column => :myseq

  def self.table_name() "matrees" end
end

class MatreeWithSymbolScope < ActiveRecord::Base
  acts_as_materialized_tree :scope => :tree, :path_column => :mypath, :seq_column => :myseq

  def self.table_name() "matrees" end
end

class MatreeWithFixedScope < ActiveRecord::Base
  acts_as_materialized_tree :scope => 'tree_id = 1', :path_column => :mypath, :seq_column => :myseq

  def self.table_name() "matrees" end
end

class MatreeWithScopeOptions < ActiveRecord::Base
  acts_as_materialized_tree :scope_options => lambda{ |o|
    {:conditions=>{:tree_id=>o.tree_id+100}, :order=>"mypath desc"}
  }, :path_column => :mypath, :seq_column => :myseq

  def self.table_name() "matrees" end
end

class MatreeOrdered < ActiveRecord::Base
  acts_as_materialized_tree :scope => :tree, :order => :other, :path_column => :mypath, :seq_column => :myseq

  def self.table_name() "matrees" end
end

class MatreeUnordered < ActiveRecord::Base
  acts_as_materialized_tree :scope => :tree, :order => nil, :path_column => :mypath, :seq_column => :myseq

  def self.table_name() "matrees" end
end

Matree = MatreeWithSymbolScope

class MatreeTest < Test::Unit::TestCase

  def setup
    ActiveRecord::Schema.define(:version => 1) do
      create_table :matrees do |t|
        t.integer :tree_id
        t.string  :mypath, :null=>false, :default=>""
        t.integer :myseq, :null=>false, :default=>0
        t.string  :other
        t.timestamps
      end
      add_index :matrees, [:tree_id,:mypath], :unique=>true
    end

    [ [nil, "", 0],
      [100, "", 35],
      [100, "0", 2],
      [100, "00", 0],
      [100, "01", 0],
      [100, "1", 0],
      [200, "", 10_000_000, "a"],
      [200, "WAA", 1, "e"],
      [200, "WAA0", 0, "d"],
      [200, "XBBBB", 1, "b"],
      [200, "XBBBB0", 0, "c"],
    ].each do |sti|
      Matree.create! :tree_id => sti[0], :mypath => sti[1], :myseq => sti[2], :other => sti[3]
    end
  end

  def teardown
    ActiveRecord::Base.connection.tables.each do |table|
      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  def node(tree_id,path)
    Matree.find_by_tree_id_and_mypath(tree_id,path)
  end

  def test_scope_options
    c = MatreeUnscoped
    n = c.new
    assert_equal({:order=>:mypath}, n.tree_scope.proxy_options)

    c = MatreeWithSymbolScope
    n = c.new
    n.tree_id = nil
    assert_equal({:order=>:mypath,:conditions=>{:tree_id => nil}}, n.tree_scope.proxy_options)
    n.tree_id = 1
    assert_equal({:order=>:mypath,:conditions=>{:tree_id => 1}}, n.tree_scope.proxy_options)
    n.tree_id = 2
    assert_equal({:order=>:mypath,:conditions=>{:tree_id => 2}}, n.tree_scope.proxy_options)

    c = MatreeWithFixedScope
    n = c.new
    n.tree_id = 3
    assert_equal({:order=>:mypath,:conditions=>"tree_id = 1"}, n.tree_scope.proxy_options)

    c = MatreeWithScopeOptions
    n = c.new
    n.tree_id = 3
    assert_equal({:order=>"mypath desc",:conditions=>{:tree_id => 103}}, n.tree_scope.proxy_options)
    n.tree_id = 4
    assert_equal({:order=>"mypath desc",:conditions=>{:tree_id => 104}}, n.tree_scope.proxy_options)

    c = MatreeOrdered
    n = c.new
    n.tree_id = 5
    assert_equal({:order=>:other,:conditions=>{:tree_id => 5}}, n.tree_scope.proxy_options)

    c = MatreeUnordered
    n = c.new
    n.tree_id = 6
    assert_equal({:conditions=>{:tree_id => 6}}, n.tree_scope.proxy_options)
  end

  def test_path_components
    m = lambda { |a,b| Matree.new(:tree_id=>a, :mypath=>b).path_components }
    assert_equal [], m[100,""]
    assert_equal ["0"], m[100,"0"]
    assert_equal ["0","1"], m[100,"01"]
    assert_equal ["WAA","0"], m[200, "WAA0"]
    assert_equal ["XBBBB","0"], m[200, "XBBBB0"]
    assert_equal ["0","W00","X0000","Y000000","Z00000000","9"],
      m[200,"0W00X0000Y000000Z000000009"]
  end
  
  def test_roots
    rr = Matree.new.roots
    assert_equal 3, rr.size
    rr.each { |r| assert_equal "", r.mypath }
    assert_equal [-1, 100, 200], rr.map { |r| r.tree_id || -1 }
  end

  def test_root?
    assert node(100,"").root?
    assert !node(100,"0").root?
  end

  def test_level
    m = lambda { |a,b| node(a,b).level }
    assert_equal 0, m[100,""]
    assert_equal 1, m[100,"0"]
    assert_equal 2, m[100,"00"]
    assert_equal 2, m[100,"01"]
    assert_equal 1, m[200,"WAA"]
  end

  def test_path_valid?
    assert Matree.new(:mypath => "WAA0").path_valid?
    assert !Matree.new(:mypath => "WAA0 ").path_valid?
  end

  def test_parent_path
    assert_equal "", Matree.new(:mypath => "").parent_path
    assert_equal "", Matree.new(:mypath => "WAA").parent_path
    assert_equal "WAA", Matree.new(:mypath => "WAA0").parent_path
    assert_equal "WAA0", Matree.new(:mypath => "WAA0XBBBB").parent_path
  end

  def test_parent
    m = lambda { |a,b| p=node(a,b).parent; [p.tree_id, p.mypath] }

    assert_equal [nil,""], m[nil,""]

    assert_equal [100,""], m[100,""]
    assert_equal [100,""], m[100,"0"]
    assert_equal [100,"0"], m[100,"01"]
  end
    
  def test_root
    [[nil,""], [100,"01"], [200,"WAA"]].each do |tid,path|
      r = node(tid, path).root
      assert_equal tid, r.tree_id
      assert_equal "", r.mypath
    end
  end

  def test_ancestor_paths
    m = lambda { |p,inc| Matree.new(:mypath => p).ancestor_paths(inc) }
    assert_equal [], m["",false]
    assert_equal [""], m["",true]
    assert_equal [""], m["WAA",false]
    assert_equal ["","WAA"], m["WAA",true]
    assert_equal ["","WAA"], m["WAA0",false]
    assert_equal ["","WAA","WAA0"], m["WAA0",true]
  end

  def test_ancestors
    m = lambda { |a,b| node(a,b).ancestors.map { |c| c.mypath } }

    assert_equal [], m[nil,""]
    
    assert_equal [], m[100,""]
    assert_equal [""], m[100,"0"]
    assert_equal ["","0"], m[100,"00"]
    
    assert_equal [], m[200, ""]
    assert_equal [""], m[200, "WAA"]
    assert_equal [""], m[200, "XBBBB"]
    assert_equal ["","WAA"], m[200, "WAA0"]
    assert_equal ["","XBBBB"], m[200, "XBBBB0"]
  end

  def test_self_and_ancestors
    m = lambda { |a,b| node(a,b).self_and_ancestors.map { |c| c.mypath } }

    assert_equal [""], m[nil,""]
    
    assert_equal [""], m[100,""]
    assert_equal ["","0"], m[100,"0"]
    assert_equal ["","0","00"], m[100,"00"]
  end

  def test_descendants
    m = lambda { |a,b| node(a,b).descendants.map { |c| c.mypath } }

    assert_equal [], m[nil,""]
    
    assert_equal ["0","00","01","1"], m[100,""]
    assert_equal ["00","01"], m[100,"0"]
    assert_equal [], m[100,"00"]
    
    assert_equal ["WAA","WAA0","XBBBB","XBBBB0"], m[200, ""]
    assert_equal ["WAA0"], m[200, "WAA"]
    assert_equal ["XBBBB0"], m[200, "XBBBB"]
    assert_equal [], m[200, "WAA0"]
    assert_equal [], m[200, "XBBBB0"]
  end

  def test_self_and_descendants
    m = lambda { |a,b| node(a,b).self_and_descendants.map { |c| c.mypath } }

    assert_equal [""], m[nil,""]
    
    assert_equal ["","0","00","01","1"], m[100,""]
    assert_equal ["0","00","01"], m[100,"0"]
    assert_equal ["00"], m[100,"00"]
  end

  def test_children
    m = lambda { |a,b| node(a,b).children.map { |c| c.mypath } }

    assert_equal [], m[nil,""]
    
    assert_equal ["0","1"], m[100,""]
    assert_equal ["00","01"], m[100,"0"]
    assert_equal [], m[100,"00"]
    
    assert_equal ["WAA","XBBBB"], m[200, ""]
    assert_equal ["WAA0"], m[200, "WAA"]
    assert_equal ["XBBBB0"], m[200, "XBBBB"]
    assert_equal [], m[200, "WAA0"]
    assert_equal [], m[200, "XBBBB0"]
  end

  def test_siblings
    m = lambda { |a,b| node(a,b).siblings.map { |c| c.mypath } }

    assert_equal [], m[nil,""]
    
    assert_equal [], m[100,""]
    assert_equal ["1"], m[100,"0"]
    assert_equal ["0"], m[100,"1"]
    assert_equal ["01"], m[100,"00"]
    assert_equal ["00"], m[100,"01"]
    
    assert_equal [], m[200,""]
    assert_equal ["XBBBB"], m[200, "WAA"]
    assert_equal ["WAA"], m[200, "XBBBB"]
    assert_equal [], m[200, "WAA0"]
    assert_equal [], m[200, "XBBBB0"]
  end

  def test_self_and_siblings
    m = lambda { |a,b| node(a,b).self_and_siblings.map { |c| c.mypath } }

    assert_equal [""], m[nil,""]
    
    assert_equal [""], m[100,""]
    assert_equal ["0","1"], m[100,"0"]
    assert_equal ["0","1"], m[100,"1"]
    assert_equal ["00","01"], m[100,"00"]
    assert_equal ["00","01"], m[100,"01"]
    
    assert_equal [""], m[200,""]
    assert_equal ["WAA","XBBBB"], m[200, "WAA"]
    assert_equal ["WAA","XBBBB",], m[200, "XBBBB"]
    assert_equal ["WAA0"], m[200, "WAA0"]
    assert_equal ["XBBBB0"], m[200, "XBBBB0"]
  end

  def test_further_constraints
    subtree = node(200,"WAA").self_and_descendants
    assert_equal 2, subtree.count
 
    subtree = node(200,"WAA").self_and_descendants
    assert_equal 1, subtree.scoped(:conditions => "mypath like '%0%'").count

    # Logs verify that these are being done via SQL count(*)
  end

  def test_ordered
    m = lambda { |a,b|
      MatreeOrdered.find_by_tree_id_and_mypath(a,b).descendants.
      map { |c| c.mypath }
    }

    assert_equal ["XBBBB","XBBBB0","WAA0","WAA"], m[200, ""]
  end

  def test_encode_path_component
    n = Matree.new
    [ [0,"0"], [9,"9"], [10,"A"], [31,"V"],
      [32,"W10"], [33,"W11"], [1023,"WVV"],
      [1024,"X0100"], [1025,"X0101"], [0xfffff, "XVVVV"],
      [0x100000,"Y010000"], [0x3fffffff,"YVVVVVV"],
      [0x40000000,"Z01000000"], [0xffffffffff,"ZVVVVVVVV"],
    ].each do |num,str|
      assert_equal str,n.send(:encode_path_component, num)
    end
    
    assert_raises(ActiveRecord::ActiveRecordError) { n.send(:encode_path_component,-1) }
    assert_raises(ActiveRecord::ActiveRecordError) { n.send(:encode_path_component,0xffffffffff+1) }
  end
  
  def test_add_new_node_1
    parent = node(100,"01")
    assert_equal 0, parent.myseq
    n = Matree.new
    assert parent.add_child(n)
    assert !n.new_record?
    assert_equal 100, n.tree_id     # note that scope col is copied
    assert_equal "010", n.mypath      # and path is allocated

    assert_not_nil node(100,"010")
    assert_equal 1, node(100,"01").myseq
  end

  def test_add_new_node_2
    parent = node(200,"")
    assert_equal 10_000_000, parent.myseq
    n = Matree.new
    assert parent.add_child(n)
    assert !n.new_record?
    assert_equal 200, n.tree_id
    assert_equal "Y09H5K0", n.mypath

    assert_not_nil node(200,"Y09H5K0")
    assert_equal 10_000_001, node(200,"").myseq
  end

  def test_graft
    parent = node(200,"WAA")
    subtree = node(200,"XBBBB")
    n1id = node(200,"XBBBB").id
    n2id = node(200,"XBBBB0").id
    parent.add_child(subtree)

    assert_equal ["WAA","WAA0","WAA1","WAA10"], node(200, "").descendants.map { |e| e.mypath }
    assert_equal n1id, node(200,"WAA1").id
    assert_equal n2id, node(200,"WAA10").id
  end

  def test_graft_between_scopes
    parent = node(200,"WAA")
    subtree = node(100,"0")
    n1id = node(100,"0").id
    n2id = node(100,"00").id
    n3id = node(100,"01").id
    parent.add_child(subtree)

    m = lambda { |a,b| node(a,b).descendants.map { |c| c.mypath } }

    assert_equal [], m[nil,""]
    assert_equal ["1"], m[100,""]
    assert_equal ["WAA","WAA0","WAA1","WAA10","WAA11","XBBBB","XBBBB0"], m[200, ""]

    assert_equal n1id, node(200,"WAA1").id
    assert_equal n2id, node(200,"WAA10").id
    assert_equal n3id, node(200,"WAA11").id
  end

  def test_add_new_child_to_new_parent
    parent = Matree.new
    child = Matree.new
    assert_raises(ActiveRecord::ActiveRecordError) { parent.add_child(child) }
  end

  def test_build_tree_from_scratch
    root = Matree.new(:tree_id => 1234, :other => "root")
    root.save!
    
    root.add_child(n1 = Matree.new(:other => "foo"))
    root.add_child(Matree.new(:other => "bar"))
    n1.add_child(Matree.new(:other => "wibble"))
    root.add_child(Matree.new(:other => "baz"))
    n1.add_child(Matree.new(:other => "bibble"))
    
    res = root.self_and_descendants.map { |e| [e.tree_id, e.mypath, e.other] }
    assert_equal [
      [ 1234, "", "root" ],
      [ 1234, "0", "foo" ],
      [ 1234, "00", "wibble" ],
      [ 1234, "01", "bibble" ],
      [ 1234, "1", "bar" ],
      [ 1234, "2", "baz" ],
    ], res
  end

  def test_destroy
    m = lambda { |a,b| node(a,b).descendants.map { |c| c.mypath } }

    node(100, "0").destroy
    assert_equal [], m[nil,""]
    assert_equal ["1"], m[100,""]
    assert_equal ["WAA","WAA0","XBBBB","XBBBB0"], m[200, ""]
  end
end

#### A test using single table inheritance, to make sure we use
#### the correct base class in queries. Here, groups can contain
#### both nested groups and users. We also have non-tree objects
#### in the same table.
####
#### Beware: Subclass.children and Subclass.descendants will find all
#### objects, including those of a different type. This is intentional,
#### but is different to Subclass.find(:all)

class Entity < ActiveRecord::Base
end

class TreeEntity < Entity
  acts_as_materialized_tree
end
class Group < TreeEntity; end
class User < TreeEntity; end

class OtherEntity < Entity; end

class STIMatreeTest < Test::Unit::TestCase
  def setup
    ActiveRecord::Schema.define(:version => 1) do
      create_table :entities do |t|
        t.string  :type
        t.string  :path
        t.integer :next_child
        t.string  :name
      end
      add_index :entities, :path, :unique=>true   # but may be null
    end
  end
  
  def teardown
    ActiveRecord::Base.connection.tables.each do |table|
      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  def maketree
    @root = Group.new(:name => "rootgroup", :path => "", :next_child => 0)
    @root.save!
    @root.add_child(n1 = Group.new(:name => "brian1"))
    @root.add_child(Group.new(:name => "brian2"))
    n1.add_child(n2 = Group.new(:name => "i'm brian"))
    n2.add_child(User.new(:name => "brian3"))
    n2.add_child(User.new(:name => "brian4"))
    n2.add_child(User.new(:name => "notbrian"))

    OtherEntity.create!(:name => "brian1000")
    OtherEntity.create!(:name => "brian1001")
  end

  def test_build
    assert_nothing_raised { maketree }

    assert_equal [
      ["Group", "", "rootgroup"],
      ["Group", "0", "brian1"],
      ["Group", "00", "i'm brian"],
      ["User",  "000", "brian3"],
      ["User",  "001", "brian4"],
      ["User",  "002", "notbrian"],
      ["Group", "1", "brian2"],
    ], @root.self_and_descendants.map { |e| [e.type, e.path, e.name] }

    assert_equal ["brian1000","brian1001"],
      OtherEntity.find(:all).map { |e| e.name }.sort
  end

  def test_search
    maketree

    assert_equal [
      ["Group","brian1"],
      ["User", "brian3"],
      ["User", "brian4"],
      ["Group", "brian2"],
    ], @root.descendants.find(:all, :conditions => "name like 'brian%'").
      map { |e| [e.type, e.name] }
    
    assert_equal ["brian1","brian2"], @root.children.map { |e| e.name }

    assert_equal ["brian3", "brian4", "notbrian"],
      Entity.find_by_name("i'm brian").children.map { |e| e.name }

    assert_equal ["brian3", "brian4"],
      Group.find_by_name("i'm brian").descendants.
        find(:all, :conditions=>"name like 'brian%'").
        map { |e| e.name }
    
    assert_equal ["brian3", "brian4", "notbrian"],
      Group.find_by_name("rootgroup").descendants.
        find(:all, :conditions=>{:type=>'User'}).
        map { |e| e.name }

    assert_equal [],
      @root.descendants.find(:all, :conditions=>{:type=>'OtherEntity'})

    assert_raises(NoMethodError) { OtherEntity.find(:first).descendants }
  end
end
