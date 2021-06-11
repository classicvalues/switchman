# frozen_string_literal: true

require "spec_helper"

module Switchman
  module ActiveRecord
    describe QueryMethods do
      include RSpecHelper

      before do
        @user1 = User.create!
        @appendage1 = @user1.appendages.create!
        @user2 = @shard1.activate { User.create! }
        @appendage2 = @user2.appendages.create!
        @user3 = @shard2.activate { User.create! }
        @appendage3 = @user3.appendages.create!
      end

      describe "#shard" do
        it "asplodes appropriately if the relation is already loaded" do
          scope = User.where(id: @user1)
          scope.to_a
          expect { scope.shard_value = @shard1 }.to raise_error(::ActiveRecord::ImmutableRelation)
        end
      end

      describe "#primary_shard" do
        it "should be the shard if it's a shard" do
          expect(User.shard(Shard.default).primary_shard).to eq Shard.default
          expect(User.shard(@shard1).primary_shard).to eq @shard1
        end

        it "should be the first shard of an array of shards" do
          expect(User.shard([Shard.default, @shard1]).primary_shard).to eq Shard.default
          expect(User.shard([@shard1, Shard.default]).primary_shard).to eq @shard1
        end

        it "should be the object's shard if it's a model" do
          expect(User.shard(@user1).primary_shard).to eq Shard.default
          expect(User.shard(@user2).primary_shard).to eq @shard1
        end

        it "should be the default shard if it's a scope of Shard" do
          expect(User.shard(Shard.all).primary_shard).to eq Shard.default
          @shard1.activate do
            expect(User.shard(Shard.all).primary_shard).to eq Shard.default
          end
        end
      end

      it "should default to the current shard" do
        relation = User.all
        expect(relation.shard_value).to eq Shard.default
        expect(relation.shard_source_value).to eq :implicit

        @shard1.activate do
          expect(relation.shard_value).to eq Shard.default

          relation = User.all
          expect(relation.shard_value).to eq @shard1
          expect(relation.shard_source_value).to eq :implicit
        end
        expect(relation.shard_value).to eq @shard1
      end

      describe "with primary key conditions" do
        it "should be changeable, and change conditions when it is changed" do
          relation = User.where(:id => @user1).shard(@shard1)
          expect(relation.shard_value).to eq @shard1
          expect(relation.shard_source_value).to eq :explicit
          expect(where_value(predicates(relation).first.right)).to eq @user1.global_id
        end

        it "should infer the shard from a single argument" do
          relation = User.where(:id => @user2)
          # execute on @shard1, with id local to that shard
          expect(relation.shard_value).to eq @shard1
          expect(where_value(predicates(relation).first.right)).to eq @user2.local_id
        end

        it "should infer the shard from multiple arguments" do
          relation = User.where(:id => [@user2, @user2])
          # execute on @shard1, with id local to that shard
          expect(relation.shard_value).to eq @shard1
          expect(where_value(predicates(relation).first.right)).to eq [@user2.local_id, @user2.local_id]
        end

        it "does not die with an array of garbage executing on another shard" do
          relation = User.where(id: ['garbage', 'more_garbage'])
          expect(relation.shard([Shard.default, @shard1]).to_a).to eq []
        end

        it "doesn't munge a subquery" do
          relation = User.where(id: User.where(id: @user1))
          expect(relation.to_a).to eq [@user1]
        end

        it "doesn't burn when plucking out of something with a FROM clause" do
          all_ids = User.from("(select * from users) as users").pluck(:id)
        end

        it "doesn't burn when plucking out of a complex query with a FROM clause" do
          # Rails can't recognize that the FROM clause is really from the users table, so
          # won't automatically prefix symbol selects. so we have to do it manually
          User.joins(:appendages).from('(select * from users) as "users"').pluck('users.id')
        end

        it "doesn't burn when plucking out of a complex query with a relational FROM clause" do
          # however, in this case we explicitly tell Rails about the table alias, and it
          # realizes it matches "users", so _does_ prefix symbol selects
          User.joins(:appendages).from(User.all, :users).pluck(:id)
        end

        it "doesn't burn in the ORDER BY clause", :focus do
          all_digits = Digit.from("(select * from digits) as \"digits\"").order(value: :desc).to_a
        end

        it "should infer the correct shard from an array of 1" do
          relation = User.where(:id => [@user2])
          # execute on @shard1, with id local to that shard
          expect(relation.shard_value).to eq @shard1
          expect(where_value(Array(predicates(relation).first.right))).to eq [@user2.local_id]
        end

        it "should do nothing when it's an array of 0" do
          relation = User.where(:id => [])
          # execute on @shard1, with id local to that shard
          expect(relation.shard_value).to eq Shard.default
          expect(where_value(predicates(relation).first.right)).to eq []
        end

        it "should order the shards preferring the shard it already had as primary" do
          relation = User.where(:id => [@user1, @user2])
          expect(relation.shard_value).to eq [Shard.default, @shard1]
          expect(where_value(predicates(relation).first.right)).to eq [@user1.local_id, @user2.global_id]

          @shard1.activate do
            relation = User.where(:id => [@user1, @user2])
            expect(relation.shard_value).to eq [@shard1, Shard.default]
            expect(where_value(predicates(relation).first.right)).to eq [@user1.global_id, @user2.local_id]
          end
        end

        it 'removes the non-pertinent primary keys when transposing for to_a' do
          relation = User.where(id: [@user1, @user2])
          original_method = User.connection.method(:exec_query)
          expect(User.connection).to receive(:exec_query).twice do |sql, type, binds|
            if ::Rails.version >= '5.2'
              if Shard.current.default?
                expect(binds.map(&:value)).to eq [@user1.id]
              else
                expect(binds.map(&:value)).to eq [@user2.id]
              end
            else
              if Shard.current.default?
                expect(sql).to match /\(#{@user1.id}\)/
              else
                expect(sql).to match /\(#{@user2.id}\)/
              end
            end
            original_method.call(sql, type, binds)
          end
          relation.to_a
        end

        it "doesn't even query a shard if no primary keys are useful" do
          relation = User.where(id: [@user1, @user2]).shard([Shard.default, @shard2])
          original_method = User.connection.method(:exec_query)
          expect(User.connection).to receive(:exec_query).once do |sql, type, binds|
            if ::Rails.version >= '5.2'
              expect(binds.map(&:value)).to eq [@user1.id]
            else
              expect(sql).to match /\(#{@user1.id}\)/
            end
            original_method.call(sql, type, binds)
          end
          relation.to_a
        end

        it "doesn't choke on valid objects with no id" do
          u = User.new
          User.where.not(id: u).shard([Shard.default, @shard1]).to_a
        end

        it "doesn't choke on NotEqual queries with valid objects on other shards" do
          u = User.create!
          User.where.not(id: u).shard([Shard.default, @shard1]).to_a
        end

        it "properly transposes ids when applying conditions after a setting a shard value" do
          @u = User.create!
          @shard1.activate { @a = Appendage.create!(:user => @u) }
          expect(User.shard([@shard1, Shard.default]).where(id: @u).first).to eq @u
          expect(Appendage.shard([@shard1, Shard.default]).where(user_id: @u).first).to eq @a

          @shard1.activate do
            @u2 = User.create!
            expect(User.shard(Shard.all).where(id: @u2).first).to eq @u2
          end
        end

        it "doesn't choke on non-integral primary keys that look like integers" do
          PageView.where(request_id: '123').take
        end

        it "doesn't change the shard for non-integral primary keys that look like global ids" do
          expect(::ActiveRecord::SchemaMigration.where(version: @shard1.global_id_for(1).to_s).shard_value).to eq Shard.default
        end

        it "transposes a global id to the shard the query will execute on" do
          u = @shard1.activate { User.create! }
          expect(User.shard(@shard1).where(id: u.id).take).to eq u
        end

        it "doesn't interpret a local id as relative to a relation's explicit shard" do
          u = @shard1.activate { User.create! }
          expect(User.shard(@shard1).where(id: u.local_id).take).to eq nil
          expect(User.shard(@shard1).where(id: u.global_id).take).to eq u
        end
      end

      describe "with foreign key conditions" do
        it "should be changeable, and change conditions when it is changed" do
          relation = Appendage.where(:user_id => @user1)
          expect(relation.shard_value).to eq Shard.default
          expect(relation.shard_source_value).to eq :implicit
          expect(where_value(predicates(relation).first.right)).to eq @user1.local_id

          relation = relation.shard(@shard1)
          expect(relation.shard_value).to eq @shard1
          expect(relation.shard_source_value).to eq :explicit
          expect(where_value(predicates(relation).first.right)).to eq @user1.global_id
        end

        it "should translate ids based on current shard" do
          relation = Appendage.where(:user_id => [@user1, @user2])
          expect(where_value(predicates(relation).first.right)).to eq [@user1.local_id, @user2.global_id]

          @shard1.activate do
            relation = Appendage.where(:user_id => [@user1, @user2])
            expect(where_value(predicates(relation).first.right)).to eq [@user1.global_id, @user2.local_id]
          end
        end

        it "should translate ids in joins" do
          relation = User.joins(:appendage).where(appendages: { user_id: [@user1, @user2]})
          expect(where_value(predicates(relation).first.right)).to eq [@user1.local_id, @user2.global_id]
        end

        it "should translate ids according to the current shard of the foreign type" do
          @shard1.activate(:mirror_universe) do
            mirror_user = MirrorUser.create!
            relation = User.where(mirror_user_id: mirror_user)
            expect(where_value(predicates(relation).first.right)).to eq mirror_user.global_id
          end
        end

        it "translates ids in array conditions when given records" do
          original_count = Appendage.count
          # create an off-shard appendage
          appendage = Appendage.create!(user: @user2)
          # make sure it ended up on this shard
          expect(Appendage.count).to eq original_count + 1
          expect(Appendage.where("user_id=?", @user2).take).to eq appendage
        end

        it "doesn't modify another relation when using bind params" do
          user = User.create!
          appendage = user.appendages.create!
          scope = user.appendages.scope
          scope.shard(@shard1)
          # the original scope should be unmodified
          expect(scope.to_a).to eq [appendage]
        end

        it "translates polymorphic conditions" do
          u = @shard1.activate { User.create! }
          f = Feature.create!(owner: u)
          expect(Feature.find_by(owner: u)).to eq f
          @shard1.activate do
            expect(Feature.shard(Shard.default).find_by(owner: u)).to eq f
          end
          @shard2.activate do
            expect(Feature.shard(Shard.default).find_by(owner: u)).to eq f
          end
        end
      end

      describe "with table aliases" do
        it "should properly construct the query (at least in Rails 4)" do
          child = @user1.children.create!
          grandchild = child.children.create!
          expect(child.reload.parent).to eq @user1

          relation = @user1.association(:grandchildren).scope

          attribute = predicates(relation).first.left
          expect(attribute.name.to_s).to eq 'parent_id'

          expect(@user1.grandchildren).to eq [grandchild]
        end
      end

      it "serializes subqueries relative to the relation's shard" do
        skip "can't detect which shard it serialized against" if Shard.default.name.include?(@shard1.name)
        sql = User.shard(@shard1).where("EXISTS (?)", User.all).to_sql
        expect(sql).not_to be_include(Shard.default.name)
        expect(sql.scan(@shard1.name).length).to eq 2
      end

      it "should be able to construct eager_load queries" do
        expect(User.eager_load(:appendages).first.association(:appendages).loaded?).to eq true
      end

      it "includes table name in select clause even with an explicit from" do
        skip "this just can't be fixed in Rails 5.1 and 5.2" unless ::Rails.version >= '6'
        expect(User.from(User.quoted_table_name).select(:id).to_sql).to eq %{SELECT "users"."id" FROM #{User.quoted_table_name}}
      end
    end
  end
end
